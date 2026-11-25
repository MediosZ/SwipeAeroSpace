import AppKit
import Foundation
import IOKit
import os

/// Detects and repairs macOS AppKit `NSTouchDevice` cache loss after sleep/wake.
///
/// On some wakes, `AppleMultitouchDriver` starts the new `AppleMultitouchDevice`
/// instance slightly before tearing down the old one, causing `WindowServer` to
/// post `com.apple.MultitouchSupport.HID.DeviceAdded` before
/// `com.apple.MultitouchSupport.HID.DeviceRemoved` for the same Multitouch
/// `"Device ID"`. AppKit's `NSTouchDevice` ignores the duplicate `DeviceAdded`
/// and then removes the device on `DeviceRemoved`, leaving `NSEvent.allTouches()`
/// permanently empty in existing processes even though the `CGEventTap` remains
/// enabled. Reconciling live IOKit `AppleMultitouchDevice` IDs against AppKit's
/// cache and re-posting `DeviceAdded` restores touch delivery without restarting.
///
/// Main-thread confined: callers (`SwipeManager`, notification observers, timers)
/// must invoke `start()`, `stop()`, `recordGestureEvent(touchCount:)`, and
/// `reconcileNow(reason:)` on `DispatchQueue.main`.
final class TouchDeviceRecovery: NSObject {
    static let deviceAddedNotification = Notification.Name(
        "com.apple.MultitouchSupport.HID.DeviceAdded"
    )
    static let deviceRemovedNotification = Notification.Name(
        "com.apple.MultitouchSupport.HID.DeviceRemoved"
    )
    static let deviceIDUserInfoKey = "Device ID"

    struct Timing {
        var deviceRemovedDelays: [TimeInterval] = [0.35, 1.5]
        var wakeDelays: [TimeInterval] = [0.5, 2.0]
        var emptyTouchThreshold: Int = 5
        var emptyTouchCheckCooldown: TimeInterval = 3.0
        var repostCooldown: TimeInterval = 1.0
        var maxRepostAttempts: Int = 2

        static let `default` = Timing()
    }

    private enum ReconcileTrigger: Hashable {
        case deviceRemoved
        case wake
    }

    private let liveDeviceIDs: () -> Set<UInt64>
    private let cachedDeviceIDs: () -> Set<UInt64>?
    private let reregisterDevice: (UInt64) -> Void
    private let workspaceNotificationCenter: NotificationCenter
    private let deviceRemovedNotificationCenter: NotificationCenter
    private let now: () -> TimeInterval
    private let timing: Timing

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "club.mediosz.SwipeAeroSpace",
        category: "Info"
    )

    private var isRunning = false
    private var wakeObserver: NSObjectProtocol?
    private var observingDeviceRemoved = false
    private var workItems: [ReconcileTrigger: [DispatchWorkItem]] = [:]
    private var consecutiveEmptyTouchFrames = 0
    private var lastEmptyTouchCheckTime = -TimeInterval.infinity
    private var lastRepostTime: [UInt64: TimeInterval] = [:]
    private var repostAttempts: [UInt64: Int] = [:]
    private var suppressedIDs: Set<UInt64> = []
    private var everCachedIDs: Set<UInt64> = []
    private var didLogMissingCacheAPI = false

    init(
        liveDeviceIDs: @escaping () -> Set<UInt64> = TouchDeviceRecovery.liveIOKitMultitouchDeviceIDs,
        cachedDeviceIDs: @escaping () -> Set<UInt64>? = TouchDeviceRecovery.cachedAppKitTouchDeviceIDs,
        reregisterDevice: @escaping (UInt64) -> Void = TouchDeviceRecovery.postDeviceAdded,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        deviceRemovedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timing: Timing = .default
    ) {
        self.liveDeviceIDs = liveDeviceIDs
        self.cachedDeviceIDs = cachedDeviceIDs
        self.reregisterDevice = reregisterDevice
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.deviceRemovedNotificationCenter = deviceRemovedNotificationCenter
        self.now = now
        self.timing = timing
        super.init()
    }

    deinit {
        teardown()
    }

    /// Starts observing multitouch detach notifications and system wake events.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isRunning else { return }
        isRunning = true

        _ = readCachedIDsAndUpdateState()

        if let distributedCenter = deviceRemovedNotificationCenter as? DistributedNotificationCenter {
            distributedCenter.addObserver(
                self,
                selector: #selector(handleDeviceRemoved(_:)),
                name: Self.deviceRemovedNotification,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        } else {
            deviceRemovedNotificationCenter.addObserver(
                self,
                selector: #selector(handleDeviceRemoved(_:)),
                name: Self.deviceRemovedNotification,
                object: nil
            )
        }
        observingDeviceRemoved = true

        wakeObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRunning else { return }
                self.resetAttemptsForKnownDevicesOnWake()
                self.scheduleReconcile(
                    delays: self.timing.wakeDelays,
                    trigger: .wake,
                    reason: "system-wake"
                )
            }
        }
    }

    /// Stops observing notifications and cancels any pending reconciliation checks.
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        teardown()
    }

    /// Tracks consecutive empty-touch gesture callbacks as a rate-limited fallback trigger.
    ///
    /// Never performs IOKit work synchronously inside the `CGEventTap` callback; when
    /// the threshold is reached outside cooldown, reconciliation is dispatched onto main.
    func recordGestureEvent(touchCount: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard touchCount == 0 else {
            consecutiveEmptyTouchFrames = 0
            return
        }
        guard isRunning else { return }
        consecutiveEmptyTouchFrames += 1
        guard consecutiveEmptyTouchFrames >= max(timing.emptyTouchThreshold, 1) else { return }

        let currentTime = now()
        guard currentTime - lastEmptyTouchCheckTime >= timing.emptyTouchCheckCooldown else { return }

        lastEmptyTouchCheckTime = currentTime
        consecutiveEmptyTouchFrames = 0
        DispatchQueue.main.async { [weak self] in
            self?.reconcileNow(reason: "empty-touch-streak")
        }
    }

    /// Compares live IOKit `AppleMultitouchDevice` IDs against AppKit's cached
    /// `NSTouchDevice` list and re-registers any missing live device IDs.
    @discardableResult
    func reconcileNow(reason: String) -> [UInt64] {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isRunning else { return [] }
        let liveIDs = liveDeviceIDs()
        guard !liveIDs.isEmpty else { return [] }

        guard let cachedIDs = readCachedIDsAndUpdateState() else {
            if !didLogMissingCacheAPI {
                didLogMissingCacheAPI = true
                logger.warning("NSTouchDevice cache lookup unavailable; skipping automatic recovery")
            }
            return []
        }

        let missingIDs = liveIDs.subtracting(cachedIDs)
        let currentTime = now()
        let attemptLimit = max(timing.maxRepostAttempts, 1)
        var recoveredIDs: [UInt64] = []

        for id in missingIDs.sorted() {
            if suppressedIDs.contains(id) {
                continue
            }
            if let previous = lastRepostTime[id], currentTime - previous < timing.repostCooldown {
                continue
            }
            let attempts = repostAttempts[id] ?? 0
            if attempts >= attemptLimit {
                suppressedIDs.insert(id)
                logger.warning(
                    "Suppressing touch device 0x\(String(id, radix: 16), privacy: .public) after \(attempts) unsuccessful recovery attempt(s)"
                )
                continue
            }

            repostAttempts[id] = attempts + 1
            lastRepostTime[id] = currentTime
            logger.info(
                "Re-registering missing touch device 0x\(String(id, radix: 16), privacy: .public) (reason: \(reason, privacy: .public), attempt: \(attempts + 1))"
            )
            reregisterDevice(id)
            recoveredIDs.append(id)
        }
        return recoveredIDs
    }

    private func readCachedIDsAndUpdateState() -> Set<UInt64>? {
        guard let cachedIDs = cachedDeviceIDs() else {
            return nil
        }
        everCachedIDs.formUnion(cachedIDs)
        for id in cachedIDs {
            repostAttempts.removeValue(forKey: id)
            suppressedIDs.remove(id)
        }
        return cachedIDs
    }

    private func resetAttemptsForKnownDevicesOnWake() {
        for id in everCachedIDs {
            repostAttempts.removeValue(forKey: id)
            suppressedIDs.remove(id)
        }
    }

    private func teardown() {
        if observingDeviceRemoved {
            deviceRemovedNotificationCenter.removeObserver(
                self,
                name: Self.deviceRemovedNotification,
                object: nil
            )
            observingDeviceRemoved = false
        }
        if let wakeObserver = wakeObserver {
            workspaceNotificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        for items in workItems.values {
            for item in items {
                item.cancel()
            }
        }
        workItems.removeAll()
        consecutiveEmptyTouchFrames = 0
        isRunning = false
    }

    @objc private func handleDeviceRemoved(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.scheduleReconcile(
                delays: self.timing.deviceRemovedDelays,
                trigger: .deviceRemoved,
                reason: "device-removed"
            )
        }
    }

    private func scheduleReconcile(
        delays: [TimeInterval],
        trigger: ReconcileTrigger,
        reason: String
    ) {
        guard isRunning else { return }
        if let existing = workItems[trigger] {
            for item in existing {
                item.cancel()
            }
        }
        var scheduled: [DispatchWorkItem] = []
        for delay in delays {
            let item = DispatchWorkItem { [weak self] in
                self?.reconcileNow(reason: reason)
            }
            scheduled.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
        workItems[trigger] = scheduled
    }

    /// Queries IOKit for all active `AppleMultitouchDevice` `"Multitouch ID"` values.
    static func liveIOKitMultitouchDeviceIDs() -> Set<UInt64> {
        guard let matching = IOServiceMatching("AppleMultitouchDevice") else {
            return []
        }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS, iterator != 0 else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var ids = Set<UInt64>()
        for _ in 0..<2 {
            ids.removeAll(keepingCapacity: true)
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let number = IORegistryEntryCreateCFProperty(
                    service,
                    "Multitouch ID" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? NSNumber else {
                    continue
                }
                let id = number.uint64Value
                if id != 0 {
                    ids.insert(id)
                }
            }
            if IOIteratorIsValid(iterator) != 0 {
                break
            }
            IOIteratorReset(iterator)
        }
        return ids
    }

    /// Reads AppKit's cached `NSTouchDevice` IDs, or returns `nil` if the runtime API changes.
    static func cachedAppKitTouchDeviceIDs() -> Set<UInt64>? {
        guard let touchDeviceClass = NSClassFromString("NSTouchDevice") as? NSObject.Type else {
            return nil
        }
        let touchDevicesSelector = NSSelectorFromString("touchDevices")
        guard touchDeviceClass.responds(to: touchDevicesSelector),
              let devices = touchDeviceClass.perform(touchDevicesSelector)?
                  .takeUnretainedValue() as? [AnyObject]
        else {
            return nil
        }

        let deviceIDSelector = NSSelectorFromString("deviceID")
        var ids = Set<UInt64>()
        for device in devices {
            guard let object = device as? NSObject,
                  object.responds(to: deviceIDSelector),
                  let number = object.value(forKey: "deviceID") as? NSNumber
            else {
                continue
            }
            let id = number.uint64Value
            if id != 0 {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Re-posts `com.apple.MultitouchSupport.HID.DeviceAdded` with `"Device ID"`.
    /// AppKit's `+[NSTouchDevice _touchDeviceAdded:]` ignores devices already present.
    static func postDeviceAdded(_ deviceID: UInt64) {
        DistributedNotificationCenter.default().postNotificationName(
            deviceAddedNotification,
            object: nil,
            userInfo: [deviceIDUserInfoKey: NSNumber(value: deviceID)],
            options: [.deliverImmediately]
        )
    }
}

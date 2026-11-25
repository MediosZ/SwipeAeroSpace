import XCTest
@testable import ConfigurationSupport

final class TouchDeviceRecoveryTests: XCTestCase {
    private let trackpadID: UInt64 = 0x200000000000033

    private func makeRecovery(
        liveDeviceIDs: @escaping () -> Set<UInt64>,
        cachedDeviceIDs: @escaping () -> Set<UInt64>?,
        reregisterDevice: @escaping (UInt64) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timing: TouchDeviceRecovery.Timing = TouchDeviceRecovery.Timing(
            deviceRemovedDelays: [0.01],
            wakeDelays: [0.01],
            emptyTouchThreshold: 5,
            emptyTouchCheckCooldown: 3.0,
            repostCooldown: 1.0,
            maxRepostAttempts: 2
        )
    ) -> (
        recovery: TouchDeviceRecovery,
        deviceRemovedCenter: NotificationCenter,
        workspaceCenter: NotificationCenter
    ) {
        let deviceRemovedCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let recovery = TouchDeviceRecovery(
            liveDeviceIDs: liveDeviceIDs,
            cachedDeviceIDs: cachedDeviceIDs,
            reregisterDevice: reregisterDevice,
            workspaceNotificationCenter: workspaceCenter,
            deviceRemovedNotificationCenter: deviceRemovedCenter,
            now: now,
            timing: timing
        )
        return (recovery, deviceRemovedCenter, workspaceCenter)
    }

    func testDeviceRemovedReaddsLiveDeviceMissingFromCache() {
        var readded: [UInt64] = []
        let exp = expectation(description: "re-adds missing live device")

        let (recovery, deviceRemovedCenter, _) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { [] },
            reregisterDevice: { id in
                readded.append(id)
                exp.fulfill()
            }
        )
        recovery.start()
        defer { recovery.stop() }

        deviceRemovedCenter.post(
            name: TouchDeviceRecovery.deviceRemovedNotification,
            object: nil,
            userInfo: [TouchDeviceRecovery.deviceIDUserInfoKey: NSNumber(value: trackpadID)]
        )

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(readded, [trackpadID])
    }

    func testDeviceRemovedIsNoopWhenDeviceAlreadyCached() {
        var readded: [UInt64] = []
        let unexpected = expectation(description: "does not re-add cached device")
        unexpected.isInverted = true

        let (recovery, deviceRemovedCenter, _) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { [self.trackpadID] },
            reregisterDevice: { id in
                readded.append(id)
                unexpected.fulfill()
            }
        )
        recovery.start()
        defer { recovery.stop() }

        deviceRemovedCenter.post(
            name: TouchDeviceRecovery.deviceRemovedNotification,
            object: nil
        )

        wait(for: [unexpected], timeout: 0.08)
        XCTAssertTrue(readded.isEmpty)
    }

    func testDeviceRemovedDoesNotReaddDisconnectedDevice() {
        var readded: [UInt64] = []
        let unexpected = expectation(description: "does not re-add disconnected device")
        unexpected.isInverted = true

        let (recovery, deviceRemovedCenter, _) = makeRecovery(
            liveDeviceIDs: { [] },
            cachedDeviceIDs: { [] },
            reregisterDevice: { id in
                readded.append(id)
                unexpected.fulfill()
            }
        )
        recovery.start()
        defer { recovery.stop() }

        deviceRemovedCenter.post(
            name: TouchDeviceRecovery.deviceRemovedNotification,
            object: nil
        )

        wait(for: [unexpected], timeout: 0.08)
        XCTAssertTrue(readded.isEmpty)
    }

    func testSystemWakeReaddsMissingLiveDeviceOnly() {
        let presentID: UInt64 = 0x111
        let missingID: UInt64 = 0x222
        var readded: [UInt64] = []
        let exp = expectation(description: "re-adds only missing wake device")

        let (recovery, _, workspaceCenter) = makeRecovery(
            liveDeviceIDs: { [presentID, missingID] },
            cachedDeviceIDs: { [presentID] },
            reregisterDevice: { id in
                readded.append(id)
                exp.fulfill()
            }
        )
        recovery.start()
        defer { recovery.stop() }

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(readded, [missingID])
    }

    func testEmptyTouchStreakRecoversMissingDeviceAndRespectsCooldown() {
        var currentTime: TimeInterval = 500
        var cached: Set<UInt64> = []
        var readded: [UInt64] = []
        var exp: XCTestExpectation? = expectation(description: "empty touch streak triggers recovery")
        var unexpected: XCTestExpectation?

        let (recovery, _, _) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { cached },
            reregisterDevice: { id in
                readded.append(id)
                exp?.fulfill()
                unexpected?.fulfill()
            },
            now: { currentTime }
        )
        recovery.start()
        defer { recovery.stop() }

        // A non-empty touch frame resets the streak.
        let beforeThreshold = expectation(description: "below threshold does not trigger")
        beforeThreshold.isInverted = true
        unexpected = beforeThreshold
        let savedExp = exp
        exp = nil
        for _ in 0..<4 { recovery.recordGestureEvent(touchCount: 0) }
        recovery.recordGestureEvent(touchCount: 3)
        for _ in 0..<4 { recovery.recordGestureEvent(touchCount: 0) }
        wait(for: [beforeThreshold], timeout: 0.05)
        XCTAssertTrue(readded.isEmpty)

        // Reaching threshold (5th consecutive empty frame) triggers recovery.
        unexpected = nil
        exp = savedExp
        recovery.recordGestureEvent(touchCount: 0)
        wait(for: [savedExp!], timeout: 1.0)
        XCTAssertEqual(readded, [trackpadID])
        exp = nil

        // Another empty streak inside cooldown does not re-trigger.
        let insideCooldown = expectation(description: "cooldown prevents repeat trigger")
        insideCooldown.isInverted = true
        unexpected = insideCooldown
        currentTime += 1.0
        for _ in 0..<6 { recovery.recordGestureEvent(touchCount: 0) }
        wait(for: [insideCooldown], timeout: 0.05)
        XCTAssertEqual(readded.count, 1)

        // Once cache is healthy, even past cooldown, empty frames do not re-add.
        let healthy = expectation(description: "healthy cache does not trigger")
        healthy.isInverted = true
        unexpected = healthy
        cached = [trackpadID]
        currentTime += 10.0
        for _ in 0..<6 { recovery.recordGestureEvent(touchCount: 0) }
        wait(for: [healthy], timeout: 0.05)
        XCTAssertEqual(readded.count, 1)
    }

    func testNilCacheLookupSkipsRecoveryWithoutBroadcasting() {
        var readded: [UInt64] = []
        let unexpected = expectation(description: "skips broadcast when cache lookup is nil")
        unexpected.isInverted = true

        let (recovery, deviceRemovedCenter, workspaceCenter) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { nil },
            reregisterDevice: { id in
                readded.append(id)
                unexpected.fulfill()
            }
        )
        recovery.start()
        defer { recovery.stop() }

        for _ in 0..<6 { recovery.recordGestureEvent(touchCount: 0) }
        deviceRemovedCenter.post(name: TouchDeviceRecovery.deviceRemovedNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        wait(for: [unexpected], timeout: 0.08)
        XCTAssertTrue(readded.isEmpty)
    }

    func testStopCancelsPendingWorkAndDetachesObservers() {
        var readded: [UInt64] = []
        let unexpected = expectation(description: "stop cancels pending work and ignores later events")
        unexpected.isInverted = true

        let (recovery, deviceRemovedCenter, workspaceCenter) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { [] },
            reregisterDevice: { id in
                readded.append(id)
                unexpected.fulfill()
            },
            timing: TouchDeviceRecovery.Timing(
                deviceRemovedDelays: [0.02],
                wakeDelays: [0.02]
            )
        )
        recovery.start()

        deviceRemovedCenter.post(name: TouchDeviceRecovery.deviceRemovedNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        recovery.stop()

        // Notifications posted after stop() must also be ignored.
        deviceRemovedCenter.post(name: TouchDeviceRecovery.deviceRemovedNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        wait(for: [unexpected], timeout: 0.1)
        XCTAssertTrue(readded.isEmpty)
    }

    func testRepostCooldownPreventsDuplicatePostsAcrossOverlappingTriggers() {
        var currentTime: TimeInterval = 200
        var readded: [UInt64] = []

        let (recovery, _, _) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { [] },
            reregisterDevice: { readded.append($0) },
            now: { currentTime }
        )
        recovery.start()
        defer { recovery.stop() }

        XCTAssertEqual(recovery.reconcileNow(reason: "first"), [trackpadID])
        currentTime += 0.4
        XCTAssertEqual(recovery.reconcileNow(reason: "within-cooldown"), [])
        currentTime += 0.7
        XCTAssertEqual(recovery.reconcileNow(reason: "after-cooldown"), [trackpadID])
        XCTAssertEqual(readded, [trackpadID, trackpadID])
    }

    func testCapsRepeatedRepostsForDeviceNeverCachedByAppKit() {
        var currentTime: TimeInterval = 300
        var readded: [UInt64] = []
        let neverCachedID: UInt64 = 0x999

        let (recovery, _, workspaceCenter) = makeRecovery(
            liveDeviceIDs: { [neverCachedID] },
            cachedDeviceIDs: { [] },
            reregisterDevice: { readded.append($0) },
            now: { currentTime },
            timing: TouchDeviceRecovery.Timing(
                deviceRemovedDelays: [0.01],
                wakeDelays: [0.01],
                repostCooldown: 1.0,
                maxRepostAttempts: 2
            )
        )
        recovery.start()
        defer { recovery.stop() }

        XCTAssertEqual(recovery.reconcileNow(reason: "attempt-1"), [neverCachedID])
        currentTime += 2.0
        XCTAssertEqual(recovery.reconcileNow(reason: "attempt-2"), [neverCachedID])
        currentTime += 2.0
        // Attempt limit reached: suppresses repeated broadcast permanently for non-AppKit device.
        XCTAssertEqual(recovery.reconcileNow(reason: "attempt-3-suppressed"), [])
        XCTAssertEqual(readded, [neverCachedID, neverCachedID])

        // Even after system wake, an ID never seen in AppKit stays suppressed.
        let noBroadcastOnWake = expectation(description: "never-cached device stays suppressed after wake")
        noBroadcastOnWake.isInverted = true
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        wait(for: [noBroadcastOnWake], timeout: 0.08)
        XCTAssertEqual(readded, [neverCachedID, neverCachedID])
    }

    func testPreviouslyCachedDeviceResetsAttemptCapOnWake() {
        var currentTime: TimeInterval = 400
        var cached: Set<UInt64> = [trackpadID]
        var readded: [UInt64] = []
        var wakeExpectation: XCTestExpectation?

        let (recovery, _, workspaceCenter) = makeRecovery(
            liveDeviceIDs: { [self.trackpadID] },
            cachedDeviceIDs: { cached },
            reregisterDevice: { id in
                readded.append(id)
                wakeExpectation?.fulfill()
            },
            now: { currentTime },
            timing: TouchDeviceRecovery.Timing(
                deviceRemovedDelays: [0.01],
                wakeDelays: [0.01],
                repostCooldown: 1.0,
                maxRepostAttempts: 2
            )
        )
        // start() sees trackpadID in cachedDeviceIDs(), recording it in everCachedIDs.
        recovery.start()
        defer { recovery.stop() }

        // Simulate cache wipe where 2 reposts fail to restore immediately.
        cached = []
        XCTAssertEqual(recovery.reconcileNow(reason: "attempt-1"), [trackpadID])
        currentTime += 2.0
        XCTAssertEqual(recovery.reconcileNow(reason: "attempt-2"), [trackpadID])
        currentTime += 2.0
        XCTAssertEqual(recovery.reconcileNow(reason: "suppressed-until-wake"), [])
        XCTAssertEqual(readded.count, 2)

        // Next system wake resets attempts for previously cached trackpadID.
        currentTime += 2.0
        wakeExpectation = expectation(description: "resets attempt cap for previously cached device on wake")
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(readded.count, 3)
    }

    func testRealAppKitProcessLocalOutOfOrderRaceAndRecovery() throws {
        let liveIDs = TouchDeviceRecovery.liveIOKitMultitouchDeviceIDs()
        let initialCached = try XCTUnwrap(TouchDeviceRecovery.cachedAppKitTouchDeviceIDs())
        guard let targetID = liveIDs.intersection(initialCached).sorted().first else {
            throw XCTSkip("No physical AppleMultitouchDevice present in AppKit NSTouchDevice cache")
        }

        let touchDeviceClass: NSObject.Type = try XCTUnwrap(
            NSClassFromString("NSTouchDevice") as? NSObject.Type
        )
        let addSelector = NSSelectorFromString("_touchDeviceAdded:")
        let removeSelector = NSSelectorFromString("_touchDeviceRemoved:")
        XCTAssertTrue(touchDeviceClass.responds(to: addSelector))
        XCTAssertTrue(touchDeviceClass.responds(to: removeSelector))

        func postProcessLocalNotification(
            _ selector: Selector,
            name: Notification.Name,
            id: UInt64
        ) {
            let note = Notification(
                name: name,
                object: nil,
                userInfo: [TouchDeviceRecovery.deviceIDUserInfoKey: NSNumber(value: id)]
            )
            _ = touchDeviceClass.perform(selector, with: note)
        }

        // Always restore the test runner's in-process NSTouchDevice cache on teardown.
        addTeardownBlock {
            for id in liveIDs.intersection(initialCached) {
                postProcessLocalNotification(
                    addSelector,
                    name: TouchDeviceRecovery.deviceAddedNotification,
                    id: id
                )
            }
        }

        // Simulate the exact WindowServer race strictly in-process (no distributed broadcast):
        // DeviceAdded arrives while cached (no-op), then DeviceRemoved wipes it.
        postProcessLocalNotification(
            addSelector,
            name: TouchDeviceRecovery.deviceAddedNotification,
            id: targetID
        )
        postProcessLocalNotification(
            removeSelector,
            name: TouchDeviceRecovery.deviceRemovedNotification,
            id: targetID
        )

        let brokenCached = try XCTUnwrap(TouchDeviceRecovery.cachedAppKitTouchDeviceIDs())
        XCTAssertFalse(brokenCached.contains(targetID))

        let exp = expectation(description: "reconciles real AppKit NSTouchDevice cache in-process")
        let (recovery, localDeviceRemovedCenter, _) = makeRecovery(
            liveDeviceIDs: TouchDeviceRecovery.liveIOKitMultitouchDeviceIDs,
            cachedDeviceIDs: TouchDeviceRecovery.cachedAppKitTouchDeviceIDs,
            reregisterDevice: { id in
                postProcessLocalNotification(
                    addSelector,
                    name: TouchDeviceRecovery.deviceAddedNotification,
                    id: id
                )
                exp.fulfill()
            },
            timing: TouchDeviceRecovery.Timing(
                deviceRemovedDelays: [0.02],
                wakeDelays: [0.02]
            )
        )
        recovery.start()
        defer { recovery.stop() }

        localDeviceRemovedCenter.post(name: TouchDeviceRecovery.deviceRemovedNotification, object: nil)
        waitForExpectations(timeout: 1.0)

        let restoredCached = try XCTUnwrap(TouchDeviceRecovery.cachedAppKitTouchDeviceIDs())
        XCTAssertTrue(restoredCached.contains(targetID))
    }
}

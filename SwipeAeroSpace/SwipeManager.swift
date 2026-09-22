import Cocoa
import Foundation
import Socket
import SwiftUI
import os

enum Direction {
    case next
    case prev

    var value: String {
        switch self {
        case .next:
            "next"
        case .prev:
            "prev"
        }
    }
}

enum GestureState {
    case began
    case changed
    case ended
    case cancelled
}

enum SwipeAxis {
    case undecided
    case horizontal
    case vertical
}

enum SwipeError: Error {
    case SocketError(String)
    case CommandFail(String)
    case Unknown(String)
}

public struct ClientRequest: Codable, Sendable {
    public let args: [String]
    public let stdin: String
    public let windowId: UInt32?

    public init(
        args: [String],
        stdin: String,
        windowId: UInt32?
    ) {
        self.args = args
        self.stdin = stdin
        self.windowId = windowId
    }
}

public struct ServerAnswer: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let serverVersionAndHash: String

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        serverVersionAndHash: String
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.serverVersionAndHash = serverVersionAndHash
    }
}

class SocketInfo: ObservableObject {
    @Published var socketConnected: Bool = false
}

extension Result {
    public var isSuccess: Bool {
        switch self {
        case .success: true
        case .failure: false
        }
    }
}

class SwipeManager {
    // user settings
    @AppStorage("threshold") private var swipeThreshold: Double = 1.0
    private var internalThreshold: Float { Float(swipeThreshold) * 0.05 }
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natural") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false
    @AppStorage("fingers") private var fingers: String = "Three"
    @AppStorage("multiSwipe") private var multiSwipeEnabled: Bool = true
    @AppStorage("maxSteps") private var maxSteps: Int = 5
    @AppStorage("swipeUpOverview") private var swipeUpOverviewEnabled: Bool = true
    @AppStorage("swipeUpFingers") private var swipeUpFingers: String = "Three"
    @AppStorage("show-empty-workspaces") private var showEmptyWorkspaces: Bool = false

    var socketInfo = SocketInfo()

    private static let queueKey = DispatchSpecificKey<Void>()

    init() {
        workQueue.setSpecific(key: Self.queueKey, value: ())
    }

    private var eventTap: CFMachPort? = nil
    private var accDisX: Float = 0
    private var accDisY: Float = 0
    private var swipeUpFired: Bool = false
    private var firedPosition: Int = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var state: GestureState = .ended
    private var swipeAxis: SwipeAxis = .undecided
    private var activeFingerCount: Int = 0
    private var gestureFocusDone: Bool = false
    private var pendingSwipeWork: DispatchWorkItem? = nil
    private var socket: Socket? = nil
    private var readBuffer = Data()
    private var protocolVersion: Int = 1
    private let workQueue = DispatchQueue(label: "swipe.workspace", qos: .userInteractive)
    private let overlayController = OverlayPanelController()

    private var logger: Logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "club.mediosz.SwipeAeroSpace",
        category: "Info"
    )

    private func readExactly(count: Int) throws -> Data {
        guard let socket = socket else {
            throw SwipeError.SocketError("No socket created")
        }
        while readBuffer.count < count {
            var temp = Data()
            let bytesRead = try socket.read(into: &temp)
            if bytesRead == 0 {
                throw SwipeError.SocketError("Socket connection closed by peer")
            }
            readBuffer.append(temp)
        }
        let chunk = Data(readBuffer.prefix(count))
        readBuffer.removeFirst(count)
        return chunk
    }

    private func runCommand(args: [String], stdin: String, retry: Bool = false)
        -> Result<String, SwipeError>
    {
        guard let socket = socket else {
            return .failure(.SocketError("No socket created"))
        }
        do {
            let request: Data
            if protocolVersion == 1 {
                request = try JSONEncoder().encode(
                    ClientRequest(args: args, stdin: stdin, windowId: nil)
                )
                // Send length prefix as a 4-byte unsigned integer (little-endian)
                let requestLength = UInt32(request.count)
                let lengthData = Data([
                    UInt8(requestLength & 0xFF),
                    UInt8((requestLength >> 8) & 0xFF),
                    UInt8((requestLength >> 16) & 0xFF),
                    UInt8((requestLength >> 24) & 0xFF)
                ])
                try socket.write(from: lengthData)
            } else {
                struct OldClientRequest: Codable {
                    let command: String
                    let args: [String]
                    let stdin: String
                    let windowId: UInt32?
                    let workspace: String?
                }
                request = try JSONEncoder().encode(
                    OldClientRequest(command: "", args: args, stdin: stdin, windowId: nil, workspace: nil)
                )
            }
            // Send JSON bytes
            try socket.write(from: request)

            let result: ServerAnswer
            if protocolVersion == 1 {
                // Read response length prefix (4 bytes)
                let responseLengthData = try readExactly(count: 4)
                let responseLength = UInt32(responseLengthData[0]) |
                                     (UInt32(responseLengthData[1]) << 8) |
                                     (UInt32(responseLengthData[2]) << 16) |
                                     (UInt32(responseLengthData[3]) << 24)
                
                // Read response JSON bytes
                let responseData = try readExactly(count: Int(responseLength))
                result = try JSONDecoder().decode(
                    ServerAnswer.self,
                    from: responseData
                )
            } else {
                let _ = try Socket.wait(
                    for: [socket],
                    timeout: 0,
                    waitForever: true
                )
                var answer = Data()
                try socket.read(into: &answer)
                result = try JSONDecoder().decode(
                    ServerAnswer.self,
                    from: answer
                )
            }
            if result.exitCode != 0 {
                return .failure(.CommandFail(result.stderr))
            }
            return .success(result.stdout)

        } catch let error {
            guard let socketError = error as? Socket.Error else {
                return .failure(.Unknown(error.localizedDescription))
            }
            // if we encouter the socket error
            // try reconnect the socket and rerun the command only once.
            if retry {
                return .failure(.SocketError(socketError.localizedDescription))
            }
            logger.info("Trying reconnect socket...")
            connectSocket(reconnect: true)
            return runCommand(args: args, stdin: stdin, retry: true)
        }
    }

    private func getNonEmptyWorkspaces() -> Result<String, SwipeError> {
        let args = [
            "list-workspaces", "--monitor", "focused", "--empty", "no",
        ]
        return runCommand(args: args, stdin: "")
    }

    func showWorkspaceOverview() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            // Phase 1: quick query (3 socket calls) — show immediately
            let (shellWorkspaces, originalWs, focusedMonitorId) = self.queryWorkspacesShell()
            let originalWsOpt: String? = originalWs.isEmpty ? nil : originalWs

            let makeCallbacks: () -> (
                onSelect: (String) -> Void,
                onPreview: (String) -> Void,
                onRevert: () -> Void
            ) = { [weak self] in
                (
                    onSelect: { wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onPreview: { wsName in
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", wsName], stdin: "")
                        }
                    },
                    onRevert: {
                        guard let originalWs = originalWsOpt else { return }
                        self?.workQueue.async {
                            _ = self?.runCommand(args: ["workspace", originalWs], stdin: "")
                        }
                    }
                )
            }

            let cb = makeCallbacks()
            DispatchQueue.main.async {
                self.overlayController.show(
                    workspaces: shellWorkspaces,
                    focusedMonitorId: focusedMonitorId,
                    onSelect: cb.onSelect,
                    onPreview: cb.onPreview,
                    onRevert: cb.onRevert
                )
            }

            // Phase 2: fetch window details and update in place
            let fullWorkspaces = self.queryWindows(for: shellWorkspaces)
            DispatchQueue.main.async {
                guard self.overlayController.isVisible else { return }
                self.overlayController.update(workspaces: fullWorkspaces)
            }
        }
    }

    /// Quick query: workspace names, monitors, focused state (4 socket calls)
    /// Returns (workspaces, focusedWorkspaceName, focusedMonitorId)
    private func queryWorkspacesShell() -> ([WorkspaceInfo], String, String?) {
        let focusedResult = runCommand(
            args: ["list-workspaces", "--focused"], stdin: ""
        )
        let focusedWs = (try? focusedResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""

        // Get the monitor ID for the focused workspace
        let focusedMonitorResult = runCommand(
            args: ["list-workspaces", "--focused", "--format", "%{monitor-id}"],
            stdin: ""
        )
        let focusedMonitorId = (try? focusedMonitorResult.get())?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let monitorResult = runCommand(
            args: [
                "list-monitors", "--format", "%{monitor-id}|%{monitor-name}",
            ],
            stdin: ""
        )
        var monitorNames: [String: String] = [:]
        if let monitorOutput = try? monitorResult.get() {
            for line in monitorOutput.split(separator: "\n") {
                let parts = line.split(separator: "|", maxSplits: 1)
                if parts.count == 2 {
                    monitorNames[String(parts[0])] = String(parts[1])
                }
            }
        }

        var args = [
            "list-workspaces", "--monitor", "all",
            "--format", "%{workspace}|%{monitor-id}",
        ]
        if !showEmptyWorkspaces {
            args.append(contentsOf: ["--empty", "no"])
        }
        let allResult = runCommand(
            args: args,
            stdin: ""
        )
        guard let allOutput = try? allResult.get() else { return ([], focusedWs, focusedMonitorId) }

        let workspaces: [WorkspaceInfo] = allOutput.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = String(parts[0])
            let monitorId = String(parts[1])
            return WorkspaceInfo(
                id: name,
                windows: [],
                isFocused: name == focusedWs,
                monitorId: monitorId,
                monitorName: monitorNames[monitorId] ?? "Monitor \(monitorId)"
            )
        }
        return (workspaces, focusedWs, focusedMonitorId)
    }

    /// Fetch window details for a list of workspaces (1 socket call per workspace)
    private func queryWindows(for workspaces: [WorkspaceInfo]) -> [WorkspaceInfo] {
        return workspaces.map { ws in
            let winResult = runCommand(
                args: [
                    "list-windows", "--workspace", ws.id,
                    "--format", "%{app-name}|%{window-title}",
                ],
                stdin: ""
            )
            let windows: [WindowInfo]
            if let winOutput = try? winResult.get(),
                !winOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                windows = winOutput.split(separator: "\n").enumerated().map {
                    idx, line in
                    let parts = line.split(separator: "|", maxSplits: 1)
                    return WindowInfo(
                        id: "\(ws.id)-\(idx)",
                        appName: parts.first.map(String.init) ?? "Unknown",
                        windowTitle: parts.count > 1
                            ? String(parts[1]) : ""
                    )
                }
            } else {
                windows = []
            }
            return WorkspaceInfo(
                id: ws.id,
                windows: windows,
                isFocused: ws.isFocused,
                monitorId: ws.monitorId,
                monitorName: ws.monitorName
            )
        }
    }

    @discardableResult
    private func switchWorkspace(direction: Direction) -> Result<
        String, SwipeError
    > {

        var res = runCommand(
            args: ["list-workspaces", "--monitor", "mouse", "--visible"],
            stdin: ""
        )
        guard let mouse_on = try? res.get() else {
            return res
        }
        res = runCommand(args: ["workspace", mouse_on], stdin: "")
        guard (try? res.get()) != nil else {
            return res
        }

        var args = ["workspace", direction.value]
        if wrapWorkspace {
            args.append("--wrap-around")
        }
        var stdin = ""
        if skipEmpty {
            res = getNonEmptyWorkspaces()
            guard let ws = try? res.get() else {
                return res
            }
            stdin = ws
            if stdin != "" {
                // explicitly insert '--stdin'
                args.append("--stdin")
            }
        }
        return runCommand(args: args, stdin: stdin)
    }

    func nextWorkspace() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: .next) {
            case .success: return
            case .failure(let err): self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    func prevWorkspace() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: .prev) {
            case .success: return
            case .failure(let err): self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    private func getAeroSpaceProtocolVersion() -> Int {
        let bundleIds = ["bobko.aerospace", "bobko.aerospace.debug"]
        for id in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               let bundleURL = app.bundleURL,
               let bundle = Bundle(url: bundleURL),
               let versionStr = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
                logger.info("Found AeroSpace version: \(versionStr)")
                let cleanVersion = versionStr.components(separatedBy: "-").first ?? ""
                let parts = cleanVersion.components(separatedBy: ".").compactMap { Int($0) }
                if parts.count >= 2 {
                    let major = parts[0]
                    let minor = parts[1]
                    if major > 0 || minor >= 21 {
                        return 1
                    }
                }
                return 0
            }
        }
        return 1
    }

    func connectSocket(reconnect: Bool = false) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            performConnectSocket(reconnect: reconnect)
        } else {
            workQueue.sync {
                self.performConnectSocket(reconnect: reconnect)
            }
        }
    }

    private func performConnectSocket(reconnect: Bool = false) {
        if socket != nil && !reconnect {
            logger.warning("socket is connected")
            return
        }

        let socket_path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        protocolVersion = getAeroSpaceProtocolVersion()
        logger.info("Detected AeroSpace protocol version: \(self.protocolVersion)")
        
        do {
            socket = try Socket.create(
                family: .unix,
                type: .stream,
                proto: .unix
            )
            try socket?.connect(to: socket_path)
            
            readBuffer.removeAll()
            
            if protocolVersion == 1 {
                // Perform handshake: write version 1
                let version: UInt32 = 1
                let versionData = Data([
                    UInt8(version & 0xFF),
                    UInt8((version >> 8) & 0xFF),
                    UInt8((version >> 16) & 0xFF),
                    UInt8((version >> 24) & 0xFF)
                ])
                try socket?.write(from: versionData)
                
                // Perform handshake: read version
                let serverVersionData = try readExactly(count: 4)
                let serverVersion = UInt32(serverVersionData[0]) |
                                    (UInt32(serverVersionData[1]) << 8) |
                                    (UInt32(serverVersionData[2]) << 16) |
                                    (UInt32(serverVersionData[3]) << 24)
                if serverVersion != 1 {
                    logger.error("AeroSpace server protocol version is \(serverVersion), expected 1")
                    socket?.close()
                    socket = nil
                    DispatchQueue.main.async {
                        self.socketInfo.socketConnected = false
                    }
                    return
                }
            }

            DispatchQueue.main.async {
                self.socketInfo.socketConnected = true
            }
            logger.info("connected to socket \(socket_path) (protocol \(self.protocolVersion))")
        } catch let error {
            socket?.close()
            socket = nil
            DispatchQueue.main.async {
                self.socketInfo.socketConnected = false
            }
            logger.error("Unexpected error: \(error.localizedDescription)")
        }
    }

    func start() {
        if eventTap != nil {
            logger.warning("SwipeManager is already started")
            return
        }
        logger.info("SwipeManager start")
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: { proxy, type, cgEvent, me in
                let wrapper = Unmanaged<SwipeManager>.fromOpaque(me!)
                    .takeUnretainedValue()
                return wrapper.eventHandler(
                    proxy: proxy,
                    eventType: type,
                    cgEvent: cgEvent
                )
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if eventTap == nil {
            logger.error("SwipeManager couldn't create event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            runLoopSource,
            CFRunLoopMode.commonModes
        )
        CGEvent.tapEnable(tap: eventTap!, enable: true)

        connectSocket()
    }

    func stop() {
        logger.info("stop the app")
        workQueue.async {
            self.socket?.close()
            self.socket = nil
            DispatchQueue.main.async {
                self.socketInfo.socketConnected = false
            }
        }
    }

    private func eventHandler(
        proxy: CGEventTapProxy,
        eventType: CGEventType,
        cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue,
            let nsEvent = NSEvent(cgEvent: cgEvent)
        {
            touchEventHandler(nsEvent)
        } else if eventType == .tapDisabledByUserInput
            || eventType == .tapDisabledByTimeout
        {
            logger.info("SwipeManager tap disabled \(eventType.rawValue)")
            CGEvent.tapEnable(tap: eventTap!, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private func touchEventHandler(_ nsEvent: NSEvent) {
        let touches = nsEvent.allTouches()

        // Sometimes there are empty touch events that we have to skip. There are no empty touch events if Mission Control or App Expose use 3-finger swipes though.
        if touches.isEmpty {
            return
        }

        // AppKit marks incidental contacts, such as a thumb or palm resting on
        // the trackpad, as resting touches. Exclude them from both the finger
        // count and movement calculation while the system classifies them as
        // resting.
        let gestureTouches = Set(touches.filter { !$0.isResting })

        // Count only active touches. macOS includes `.ended` (and sometimes
        // `.stationary`) touches in the same event frame as moving fingers,
        // which can briefly inflate the count and falsely latch the gesture
        // (e.g. a 3-finger drag-to-select reporting count == 4 for one frame).
        let touchesCount = gestureTouches.filter { $0.phase != .ended }.count
        if touchesCount == 0 {
            stopGesture()
        } else {
            processTouches(touches: gestureTouches, count: touchesCount)
        }
    }

    private func stopGesture() {
        if state == .began {
            state = .ended
            if swipeAxis != .vertical {
                handleGesture()
            }
            clearEventState()
        }
    }

    private func processTouches(touches: Set<NSTouch>, count: Int) {
        let hFingerCount = fingers == "Three" ? 3 : 4
        let vFingerCount = swipeUpFingers == "Three" ? 3 : 4
        if state != .began && (count == hFingerCount || count == vFingerCount) {
            state = .began
            activeFingerCount = count
        }
        // While axis is still undecided, cancel the gesture if the active
        // count drifts entirely outside the valid range (neither matches the
        // horizontal nor the vertical finger count). Do NOT update
        // `activeFingerCount` here — lowering it on a transient drop would
        // silently swallow legitimate gestures where a finger briefly lifts.
        if state == .began && swipeAxis == .undecided
            && count != hFingerCount && count != vFingerCount
        {
            state = .ended
            clearEventState()
            return
        }
        if state == .began {
            let (disX, disY) = swipeDistance(touches: touches)
            accDisX += disX
            accDisY += disY

            // Lock axis once we have enough movement
            if swipeAxis == .undecided {
                let threshold = internalThreshold * 0.3
                if abs(accDisX) > threshold || abs(accDisY) > threshold {
                    swipeAxis =
                        abs(accDisY) > abs(accDisX) ? .vertical : .horizontal
                }
            }

            // Vertical swipes: only fire if finger count matches overview setting
            if swipeAxis == .vertical && swipeUpOverviewEnabled
                && activeFingerCount == vFingerCount
            {
                let threshold = internalThreshold * 0.5
                if !swipeUpFired && accDisY > threshold {
                    swipeUpFired = true
                    if !overlayController.isVisible {
                        showWorkspaceOverview()
                    }
                }
                // Mid-gesture: swipe back down dismisses when accDisY reverses
                if swipeUpFired && accDisY < threshold * 0.5 {
                    swipeUpFired = false
                    DispatchQueue.main.async { [weak self] in
                        self?.overlayController.dismiss()
                    }
                }
                // New gesture: swipe down dismisses if overlay is already open
                if !swipeUpFired && accDisY < -threshold
                    && overlayController.isVisible
                {
                    swipeUpFired = true
                    DispatchQueue.main.async { [weak self] in
                        self?.overlayController.dismiss()
                    }
                }
            }

            // Only fire horizontal workspace switches for horizontal swipes
            // and only when the active finger count matches the configured
            // finger count (mirrors the guard on the vertical/overview path).
            if swipeAxis == .horizontal && multiSwipeEnabled && activeFingerCount == hFingerCount {
                let threshold = internalThreshold
                let rawPosition = Int(accDisX / threshold)
                let targetPosition = max(-maxSteps, min(maxSteps, rawPosition))
                let delta = targetPosition - firedPosition

                if delta != 0 {
                    let direction: Direction
                    if delta > 0 {
                        direction = naturalSwipe ? .prev : .next
                    } else {
                        direction = naturalSwipe ? .next : .prev
                    }
                    let stepsToFire = abs(delta)
                    firedPosition = targetPosition

                    // Cancel any pending work so we don't overshoot
                    pendingSwipeWork?.cancel()

                    let workItem = DispatchWorkItem { [weak self] in
                        guard let self = self else { return }

                        // Focus the workspace under the cursor once per gesture
                        if !self.gestureFocusDone {
                            let res = self.runCommand(
                                args: ["list-workspaces", "--monitor", "mouse", "--visible"],
                                stdin: ""
                            )
                            if let mouseWs = try? res.get() {
                                _ = self.runCommand(args: ["workspace", mouseWs], stdin: "")
                            }
                            self.gestureFocusDone = true
                        }

                        // Fire only the lean next/prev calls
                        for _ in 0..<stepsToFire {
                            var args = ["workspace", direction.value]
                            var stdin = ""
                            if self.wrapWorkspace {
                                args.append("--wrap-around")
                            }
                            if self.skipEmpty {
                                if let ws = try? self.getNonEmptyWorkspaces().get(), !ws.isEmpty {
                                    stdin = ws
                                    args.append("--stdin")
                                }
                            }
                            switch self.runCommand(args: args, stdin: stdin) {
                            case .success: continue
                            case .failure(let err):
                                self.logger.error("\(err.localizedDescription)")
                                return
                            }
                        }
                    }
                    pendingSwipeWork = workItem
                    workQueue.async(execute: workItem)
                }
            }
        }
    }

    private func clearEventState() {
        accDisX = 0
        accDisY = 0
        firedPosition = 0
        swipeUpFired = false
        swipeAxis = .undecided
        activeFingerCount = 0
        gestureFocusDone = false
        prevTouchPositions.removeAll()
    }

    private func handleGesture() {
        // If multi-swipe is enabled, switches already fired live during the gesture
        if multiSwipeEnabled {
            return
        }
        // Mirror the multi-swipe path's finger-count guard: only fire when
        // the active count matches the configured horizontal finger count.
        let hFingerCount = fingers == "Three" ? 3 : 4
        if activeFingerCount != hFingerCount {
            return
        }
        let threshold = internalThreshold
        if abs(accDisX) < threshold {
            return
        }
        let direction: Direction =
            if naturalSwipe {
                accDisX < 0 ? .next : .prev
            } else {
                accDisX < 0 ? .prev : .next
            }
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch self.switchWorkspace(direction: direction) {
            case .success: return
            case .failure(let err):
                self.logger.error("\(err.localizedDescription)")
            }
        }
    }

    private func swipeDistance(touches: Set<NSTouch>) -> (Float, Float) {
        var allRight = true
        var allLeft = true
        var allUp = true
        var allDown = true
        var sumDisX = Float(0)
        var sumDisY = Float(0)
        var activeTouches = 0
        for touch in touches {
            let (disX, disY) = touchDistance(touch)
            allRight = allRight && disX >= 0
            allLeft = allLeft && disX <= 0
            allUp = allUp && disY >= 0
            allDown = allDown && disY <= 0
            sumDisX += disX
            sumDisY += disY

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] =
                    touch.normalizedPosition
                activeTouches += 1
            }
        }

        // Average across fingers so threshold behaves consistently
        // regardless of finger count
        let count = max(activeTouches, 1)
        var resultX = sumDisX / Float(count)
        var resultY = sumDisY / Float(count)

        // All fingers should move in the same direction for each axis.
        if !allRight && !allLeft {
            resultX = 0
        }
        if !allUp && !allDown {
            resultY = 0
        }

        return (resultX, resultY)
    }

    private func touchDistance(_ touch: NSTouch) -> (Float, Float) {
        guard let prevPosition = prevTouchPositions["\(touch.identity)"] else {
            return (0, 0)
        }
        let position = touch.normalizedPosition
        return (
            Float(position.x - prevPosition.x),
            Float(position.y - prevPosition.y)
        )
    }
}

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

enum SwipeError: Error {
    case SocketError
    case CommandFail(String)
    case Unknown(String)
}

public struct ClientRequest: Codable, Sendable {
    public let command: String
    public let args: [String]
    public let stdin: String

    public init(
        args: [String],
        stdin: String
    ) {
        self.command = ""
        self.args = args
        self.stdin = stdin
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
    @AppStorage("threshold") private var swipeThreshold: Double = 0.3
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natrual") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false
    @AppStorage("qwerty-swipe") private var qwertySwipe: Bool = false

    var socketInfo = SocketInfo()

    private var eventTap: CFMachPort? = nil
    private var accDisX: Float = 0
    private var prevTouchPositions: [String: NSPoint] = [:]
    private var state: GestureState = .ended
    private var socket: Socket? = nil

    private func runCommand(args: [String], stdin: String) -> Result<String, SwipeError> {
        guard let socket = socket else { return .failure(.SocketError) }
        do {
            let request = try JSONEncoder().encode(ClientRequest(args: args, stdin: stdin))
            try socket.write(from: request)
            let _ = try Socket.wait(for: [socket], timeout: 0, waitForever: true)
            var answer = Data()
            try socket.read(into: &answer)
            let result = try JSONDecoder().decode(ServerAnswer.self, from: answer)
            if result.exitCode != 0 {
                return .failure(.CommandFail(result.stderr))
            }

            return .success(result.stdout)

        } catch let error {
            return .failure(.Unknown(error.localizedDescription))
        }
    }

    private func getNonEmptyWorkspaces() -> Result<String, SwipeError> {
        let args = [
            "list-workspaces", "--monitor", "focused", "--empty", "no",
        ]
        return runCommand(args: args, stdin: "")
    }

    @discardableResult
    private func switchWorkspace(direction: Direction) -> Result<String, SwipeError> {
        var workspaceOrder: [String] = [
            "1", "2", "3", "4", "5", "6", "7", "8", "9",
            "A", "B", "C", "D", "E", "F", "G", "H", "I",
            "J", "K", "L", "M", "N", "O", "P", "Q", "R",
            "S", "T", "U", "V", "W", "X", "Y", "Z",
        ]
        if qwertySwipe {
            workspaceOrder = [
                "1", "2", "3", "4", "5", "6", "7", "8", "9",
                "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P",
                "A", "S", "D", "F", "G", "H", "J", "K", "L",
                "Z", "X", "C", "V", "B", "N", "M",
            ]
        }

        var res = runCommand(
            args: ["list-workspaces", "--monitor", "mouse", "--visible"], stdin: "")
        guard let mouse_on_raw = try? res.get() else {
            return res
        }
        let mouse_on = mouse_on_raw.uppercased()

        res = runCommand(args: ["list-workspaces", "--all"], stdin: "")
        guard let wsListRaw = try? res.get() else {
            return res
        }

        let allWorkspaces =
            wsListRaw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }

        let filteredWorkspaces: [String]
        if skipEmpty {
            res = getNonEmptyWorkspaces()
            guard let nonEmptyRaw = try? res.get() else {
                return res
            }
            filteredWorkspaces =
                nonEmptyRaw
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
        } else {
            filteredWorkspaces = allWorkspaces
        }

        let normalizedCurrentIndex =
            workspaceOrder.firstIndex(of: mouse_on)
            ?? {
                for (i, name) in workspaceOrder.enumerated() {
                    if filteredWorkspaces.contains(name) {
                        return i
                    }
                }
                return -1
            }()

        if normalizedCurrentIndex == -1 {
            return .failure(.CommandFail("Workspace not found"))
        }

        let count = workspaceOrder.count
        let offset = direction == .next ? 1 : -1

        if wrapWorkspace {
            for i in 1..<count {
                let index = (normalizedCurrentIndex + i * offset + count) % count
                let candidate = workspaceOrder[index]
                if filteredWorkspaces.contains(candidate) {
                    return runCommand(args: ["workspace", candidate], stdin: "")
                }
            }
        } else {
            var index = normalizedCurrentIndex + offset
            while index >= 0 && index < count {
                let candidate = workspaceOrder[index]
                if filteredWorkspaces.contains(candidate) {
                    return runCommand(args: ["workspace", candidate], stdin: "")
                }
                index += offset
            }
        }

        return .failure(.CommandFail("Workspace not found"))
    }

    func nextWorkspace() {
        switchWorkspace(direction: .next)
    }

    func prevWorkspace() {
        switchWorkspace(direction: .prev)
    }

    func connectSocket(reconnect: Bool = false) {
        if socket != nil && !reconnect {
            debugPrint("socket is connected")
            return
        }

        let socket_path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        do {
            socket = try Socket.create(family: .unix, type: .stream, proto: .unix)
            try socket?.connect(to: socket_path)
            socketInfo.socketConnected = true
            debugPrint("connect to socket \(socket_path)")
        } catch let error {
            debugPrint("Unexpected error: \(error.localizedDescription)")
        }
    }

    func start() {
        if eventTap != nil {
            debugPrint("SwipeManager is already started")
            return
        }
        debugPrint("SwipeManager start")
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
            callback: { proxy, type, cgEvent, me in
                let wrapper = Unmanaged<SwipeManager>.fromOpaque(me!).takeUnretainedValue()
                return wrapper.eventHandler(
                    proxy: proxy, eventType: type, cgEvent: cgEvent)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if eventTap == nil {
            debugPrint("SwipeManager couldn't create event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: eventTap!, enable: true)

        connectSocket()
    }

    func stop() {
        debugPrint("stop the app")
        socket?.close()
    }

    private func eventHandler(
        proxy: CGEventTapProxy, eventType: CGEventType, cgEvent: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType.rawValue == NSEvent.EventType.gesture.rawValue,
            let nsEvent = NSEvent(cgEvent: cgEvent)
        {
            touchEventHandler(nsEvent)
        } else if eventType == .tapDisabledByUserInput
            || eventType == .tapDisabledByTimeout
        {
            debugPrint("SwipeManager tap disabled", eventType.rawValue)
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
        let touchesCount =
            touches.allSatisfy({ $0.phase == .ended }) ? 0 : touches.count
        if touchesCount == 0 {
            stopGesture()
        } else {
            processThreeFingers(touches: touches, count: touchesCount)
        }
    }

    private func stopGesture() {
        if state == .began {
            state = .ended
            handleGesture()
            clearEventState()
        }
    }

    private func processThreeFingers(touches: Set<NSTouch>, count: Int) {
        if state != .began && count == 3 {
            state = .began
        }
        if state == .began {
            accDisX += horizontalSwipeDistance(touches: touches)
        }
    }

    private func clearEventState() {
        accDisX = 0
        prevTouchPositions.removeAll()
    }

    private func handleGesture() {
        // filter
        if abs(accDisX) < Float(swipeThreshold) {
            return
        }
        let direction: Direction =
            if naturalSwipe {
                accDisX < 0 ? .next : .prev
            } else {
                accDisX < 0 ? .prev : .next
            }
        switchWorkspace(direction: direction)
    }

    private func horizontalSwipeDistance(touches: Set<NSTouch>) -> Float {
        var allRight = true
        var allLeft = true
        var sumDisX = Float(0)
        var sumDisY = Float(0)
        for touch in touches {
            let (disX, disY) = touchDistance(touch)
            allRight = allRight && disX >= 0
            allLeft = allLeft && disX <= 0
            sumDisX += disX
            sumDisY += disY

            if touch.phase == .ended {
                prevTouchPositions.removeValue(forKey: "\(touch.identity)")
            } else {
                prevTouchPositions["\(touch.identity)"] =
                    touch.normalizedPosition
            }
        }
        // All fingers should move in the same direction.
        if !allRight && !allLeft {
            return 0
        }

        // Only horizontal swipes are interesting.
        if abs(sumDisX) <= abs(sumDisY) {
            return 0
        }

        return sumDisX
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

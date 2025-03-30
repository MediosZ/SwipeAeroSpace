import Cocoa
import Foundation
import SwiftUI
import os
import Socket

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


class SwipeManager{
    // user settings
    @AppStorage("aerospace") private var executable: String =
        "/opt/homebrew/bin/aerospace"
    @AppStorage("threshold") private var swipeThreshold: Double = 0.3
    @AppStorage("wrap") private var wrapWorkspace: Bool = false
    @AppStorage("natrual") private var naturalSwipe: Bool = true
    @AppStorage("skip-empty") private var skipEmpty: Bool = false

//    @Published public var socketConnected: Bool = false
    
    var socketInfo = SocketInfo()
    
    private var eventTap: CFMachPort? = nil
    // Event state.
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
            
        }
        catch let error {
            return .failure(.Unknown(error.localizedDescription))
        }
    }
    
    private func getNonEmptyWorkspaces() -> String {
        let args = [
            "list-workspaces", "--monitor", "focused", "--empty", "no"
        ]
        switch runCommand(args: args, stdin: "") {
        case .success(let ws):
            return ws
        case .failure(let error):
            debugPrint("something went wrong, error: \(error)")
            return ""
        }
    }
    
    
    private func switchWorkspace(direction: Direction) -> String {
        if socket != nil {
            var args = ["workspace", direction.value]
            if wrapWorkspace {
                args.append("--wrap-around")
            }
            let stdin = skipEmpty ? getNonEmptyWorkspaces() : ""
            
            
            switch runCommand(args: args, stdin: stdin) {
            case .success(let output):
                return output
            case .failure(let error):
                return error.localizedDescription
            }
        }
        else {
            let wrap = wrapWorkspace ? "--wrap-around" : ""
            let skip_empty_command = skipEmpty ? "\(executable) list-workspaces --monitor focused --empty no |" : ""
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = [
                "-c",
                "\(executable) workspace $(\(executable) list-workspaces --monitor mouse --visible) && \(skip_empty_command) \(executable) workspace \(wrap) \(direction.value)",
            ]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
            } catch {
                debugPrint("something went wrong, error: \(error)")
            }
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output: String = String(data: data, encoding: .utf8) ?? ""

            return output
        }
    }

    public func nextWorkspace() {
        let _ = switchWorkspace(direction: .next)
    }

    public func prevWorkspace() {
        let _ = switchWorkspace(direction: .prev)
    }
    
    public func socketStatus() -> Bool {
        socket != nil
    }
    
    public func connectSocket(reconnect: Bool = false) {
        if socket != nil && !reconnect{
            debugPrint("socket is connected")
            return
        }
        
        let socket_path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
        do {
            socket = try Socket.create(family: .unix, type: .stream, proto: .unix)
            try socket?.connect(to: socket_path)
//            socketConnected = true
            socketInfo.socketConnected = true
            debugPrint("connect to socket \(socket_path)")
        }
        catch let error {
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
    
    public func stop() {
        debugPrint("stop the app")
        socket?.close()
    }

    public func eventHandler(
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
        let direction: Direction = if naturalSwipe {
            accDisX < 0 ? .next : .prev
        }
        else {
            accDisX < 0 ? .prev : .next
        }
        let _ = switchWorkspace(direction: direction)
    }

    private func horizontalSwipeDistance(touches: Set<NSTouch>) -> Float
    {
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

import Cocoa
import Foundation
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

func switchWorkspace(executable: String, direction: Direction, wrapWorkspace: Bool) -> String {
    let wrap = wrapWorkspace ? "--wrap-around" : ""
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = [
        "-c",
        "\(executable) workspace $(\(executable) list-workspaces --monitor mouse --visible) && \(executable) workspace \(wrap) \(direction.value)",
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

class SwipeManager {
    // user settings
    @AppStorage("aerospace") private static var aerospace: String =
        "/opt/homebrew/bin/aerospace"
    @AppStorage("threshold") private static var swipeThreshold: Double = 0.3
    @AppStorage("wrap") private static var wrapWorkspace: Bool = false
    @AppStorage("natrual") private static var naturalSwipe: Bool = true

    private static var eventTap: CFMachPort? = nil
    // Event state.
    private static var accDisX: Float = 0
    private static var prevTouchPositions: [String: NSPoint] = [:]
    private static var state: GestureState = .ended

    public static func nextWorkspace() {
        let _ = switchWorkspace(executable: aerospace, direction: .next, wrapWorkspace: wrapWorkspace)
    }

    public static func prevWorkspace() {
        let _ = switchWorkspace(executable: aerospace, direction: .prev, wrapWorkspace: wrapWorkspace)
    }

    static func start() {
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
            callback: { proxy, type, cgEvent, userInfo in
                return SwipeManager.eventHandler(
                    proxy: proxy, eventType: type, cgEvent: cgEvent,
                    userInfo: userInfo)
            },
            userInfo: nil
        )
        if eventTap == nil {
            debugPrint("SwipeManager couldn't create event tap")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(), runLoopSource, CFRunLoopMode.commonModes)
        CGEvent.tapEnable(tap: eventTap!, enable: true)
    }

    private static func eventHandler(
        proxy: CGEventTapProxy, eventType: CGEventType, cgEvent: CGEvent,
        userInfo: UnsafeMutableRawPointer?
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

    private static func touchEventHandler(_ nsEvent: NSEvent) {
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

    private static func stopGesture() {
        if state == .began {
            debugPrint("handle gesture")
            state = .ended
            handleGesture()
            clearEventState()
        }
    }

    private static func processThreeFingers(touches: Set<NSTouch>, count: Int) {
        if state != .began && count == 3 {
            debugPrint("start swipe")
            state = .began
        }
        if state == .began {
            accDisX += horizontalSwipeDistance(touches: touches)
        }
    }

    private static func clearEventState() {
        accDisX = 0
        prevTouchPositions.removeAll()
    }

    private static func handleGesture() {
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
        let _ = switchWorkspace(
            executable: aerospace, direction: direction, wrapWorkspace: wrapWorkspace)
    }

    private static func horizontalSwipeDistance(touches: Set<NSTouch>) -> Float
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

    private static func touchDistance(_ touch: NSTouch) -> (Float, Float) {
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

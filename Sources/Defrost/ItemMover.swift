// LICENSE NOTE: The item-moving event recipe is adapted from Ice's macos-26
// branch (https://github.com/jordanbaird/Ice, GPL-3.0). Used on macOS 14–26 only.

import AppKit
import CoreGraphics

/// Moves status items by sending the synthetic Cmd-drag that macOS uses to
/// rearrange them.
///
/// The event recipe follows Ice's macos-26 branch:
/// - Target the events at the item's own app, not at the window owner, which
///   is Control Center on macOS 26.
/// - Press at the destination rather than at the item.
/// - Deliver each event to both the session tap and the app.
/// - Send mouse-up twice.
///
/// This works for items that are hidden off-screen, so nothing has to be
/// revealed, and the cursor is hidden and put back. It only runs during
/// reconciliation, never while idle.
enum ItemMover {
    enum Destination {
        case leftOf(MenuBarItem)
        case rightOf(MenuBarItem)

        var target: MenuBarItem {
            switch self {
            case .leftOf(let t), .rightOf(let t): t
            }
        }
    }

    enum MoveError: Error {
        case noFrame
        case eventCreation
        case didNotMove
    }

    /// Lets Defrost hide the cursor while it isn't the frontmost app. Call once at launch.
    static func enableBackgroundCursorControl() {
        let cid = CGSMainConnectionID()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// Moves `item` and returns once it sits on the correct side of the target. Must run off the main thread.
    static func move(_ item: MenuBarItem, to destination: Destination) throws {
        precondition(!Thread.isMainThread)
        if try isInPlace(item, destination) { return }

        let savedCursor = CGEvent(source: nil)?.location ?? .zero
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            CGWarpMouseCursorPosition(savedCursor)
            CGDisplayShowCursor(CGMainDisplayID())
        }

        for attempt in 1...3 {
            try postMove(item, to: destination)
            if try isInPlace(item, destination) { return }
            Log.info("move attempt \(attempt) for \(item.id) did not land")
            usleep(50_000)
        }
        throw MoveError.didNotMove
    }

    private static func isInPlace(_ item: MenuBarItem, _ destination: Destination) throws -> Bool {
        guard let i = Bridging.frame(of: item.windowID),
              let t = Bridging.frame(of: destination.target.windowID) else { throw MoveError.noFrame }
        switch destination {
        case .leftOf: return i.maxX <= t.minX + 1 && t.minX - i.maxX < 2
        case .rightOf: return i.minX >= t.maxX - 1 && i.minX - t.maxX < 2
        }
    }

    private static func postMove(_ item: MenuBarItem, to destination: Destination) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw MoveError.eventCreation }
        if let combined = CGEventSource(stateID: .combinedSessionState) {
            for state in [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag, .eventSuppressionStateSuppressionInterval] {
                combined.setLocalEventsFilterDuringSuppressionState(.permitAllEvents, state: state)
            }
            combined.localEventsSuppressionInterval = 0
        }
        guard let itemFrame = Bridging.frame(of: item.windowID),
              let targetFrame = Bridging.frame(of: destination.target.windowID) else { throw MoveError.noFrame }

        var start: CGPoint
        var end: CGPoint
        switch destination {
        case .leftOf:
            start = CGPoint(x: targetFrame.minX, y: targetFrame.minY)
            end = start
            if itemFrame.maxX <= targetFrame.minX { end.x -= itemFrame.width } else { start.x -= 1 }
        case .rightOf:
            start = CGPoint(x: targetFrame.maxX, y: targetFrame.minY)
            end = start
            if itemFrame.minX <= targetFrame.maxX { end.x -= itemFrame.width } else { start.x += 1 }
        }

        let pid = item.appPID
        guard let down = event(.leftMouseDown, at: start, windowID: item.windowID, pid: pid, source: source),
              let up = event(.leftMouseUp, at: end, windowID: destination.target.windowID, pid: pid, source: source)
        else { throw MoveError.eventCreation }

        deliver(down, to: pid)
        let afterDown = waitForChange(of: item.windowID, from: itemFrame.origin, timeout: 0.3) ?? itemFrame.origin
        deliver(up, to: pid)
        usleep(10_000)
        deliver(up, to: pid) // A second mouse-up avoids leaving the item mid-drag.
        _ = waitForChange(of: item.windowID, from: afterDown, timeout: 0.3)
    }

    private static func deliver(_ event: CGEvent, to pid: pid_t) {
        event.post(tap: .cgSessionEventTap)
        event.postToPid(pid)
    }

    private static func event(_ type: CGEventType, at location: CGPoint, windowID: CGWindowID, pid: pid_t, source: CGEventSource) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { return nil }
        e.flags = .maskCommand
        let wid = Int64(windowID)
        e.setIntegerValueField(.eventSourceUserData, value: Int64(Int(bitPattern: ObjectIdentifier(e))))
        e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: wid)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: wid)
        e.setIntegerValueField(.windowID, value: wid)
        return e
    }

    /// Short, bounded wait used only during a move.
    private static func waitForChange(of windowID: CGWindowID, from origin: CGPoint, timeout: TimeInterval) -> CGPoint? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(5_000)
            if let f = Bridging.frame(of: windowID), f.origin != origin { return f.origin }
        }
        return nil
    }
}

private extension CGEventFilterMask {
    static let permitAllEvents: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
}

private extension CGEventField {
    /// Undocumented window ID field (from Ice).
    static let windowID = CGEventField(rawValue: 0x33)!
}

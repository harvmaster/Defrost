// LICENSE NOTE: These private SkyLight declarations follow Ice
// (https://github.com/jordanbaird/Ice, GPL-3.0). Used on macOS 14–26 only.

import CoreGraphics
import Foundation

// Private SkyLight (CoreGraphics Services) functions. These are the same
// calls Ice relies on; they are only used on demand, never on a timer.

typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetProcessMenuBarWindowList")
func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ outCount: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
func CGSGetScreenRectForWindow(
    _ cid: CGSConnectionID,
    _ wid: CGWindowID,
    _ outRect: inout CGRect
) -> CGError

@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ key: CFString,
    _ value: CFTypeRef
) -> CGError

@_silgen_name("CGSGetWindowOwner")
func CGSGetWindowOwner(
    _ cid: CGSConnectionID,
    _ wid: CGWindowID,
    _ outOwner: inout CGSConnectionID
) -> CGError

@_silgen_name("CGSConnectionGetPID")
func CGSConnectionGetPID(
    _ cid: CGSConnectionID,
    _ outPID: inout pid_t
) -> CGError

enum Bridging {
    private static let cid = CGSMainConnectionID()

    /// All menu bar windows (status items plus the app menu bar), in no particular order.
    static func menuBarWindowIDs() -> [CGWindowID] {
        var list = [CGWindowID](repeating: 0, count: 512)
        var count: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(cid, 0, Int32(list.count), &list, &count) == .success else {
            return []
        }
        return Array(list.prefix(Int(count)))
    }

    /// The current on-screen frame of a window (top-left origin, global coordinates).
    static func frame(of windowID: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        guard CGSGetScreenRectForWindow(cid, windowID, &rect) == .success else {
            return nil
        }
        return rect
    }

    /// The PID of the process that owns a window. On macOS 26 this is
    /// Control Center for every status item.
    static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        var owner: CGSConnectionID = 0
        guard CGSGetWindowOwner(cid, windowID, &owner) == .success else {
            return nil
        }
        var pid: pid_t = 0
        guard CGSConnectionGetPID(owner, &pid) == .success else {
            return nil
        }
        return pid
    }
}

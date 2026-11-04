import AppKit
import ApplicationServices

/// A status item currently in the menu bar.
struct MenuBarItem: Identifiable, Equatable {
    /// Stable identifier used in the config, e.g. "com.apple.menuextra.battery" or "ru.keepcoder.Telegram#0".
    let id: String
    let windowID: CGWindowID
    /// Global frame, top-left origin.
    var frame: CGRect
    /// PID of the window's owner, which is the target for synthetic events.
    /// On macOS 26 this is Control Center for every item.
    let windowOwnerPID: pid_t
    let appPID: pid_t
    let bundleID: String
    let appName: String
    let label: String
    /// "A" or "N" for Defrost's own dividers.
    let dividerName: String?

    var isDivider: Bool { dividerName != nil }

    /// Items macOS does not let you move.
    var isFixed: Bool {
        MenuBarItem.fixedIDs.contains(id)
    }

    static let fixedIDs: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
    ]

    var displayName: String {
        if label.isEmpty || label == appName { return appName }
        return "\(appName) — \(label)"
    }
}

enum MenuBarItems {
    private struct AXItem {
        let pid: pid_t
        let bundleID: String
        let appName: String
        let identifier: String?
        let label: String
        let frame: CGRect
    }

    /// Lists all status items left-to-right, as macOS 26 sees them. Status
    /// item windows are owned by Control Center there, so each window is
    /// matched to its app through that app's Accessibility "extras menu bar".
    ///
    /// Must not run on the main thread, because it queries Defrost's own process too.
    static func current() -> [MenuBarItem] {
        precondition(!Thread.isMainThread, "MenuBarItems.current() must run off the main thread")

        let windows: [(CGWindowID, CGRect)] = Bridging.menuBarWindowIDs().compactMap { wid in
            guard let frame = Bridging.frame(of: wid), frame.height < 60 else { return nil }
            return (wid, frame)
        }
        let axItems = collectAXItems()

        var used = Set<CGWindowID>()
        var perAppIndex: [String: Int] = [:]
        var result: [MenuBarItem] = []

        // Assign stable "#n" indexes per app counting from the right, which is
        // where macOS anchors status items.
        for ax in axItems.sorted(by: { $0.frame.maxX > $1.frame.maxX }) {
            guard let (wid, frame) = bestWindow(for: ax.frame, in: windows, excluding: used) else { continue }
            used.insert(wid)

            let dividerName: String? = {
                guard let ident = ax.identifier, ident.hasPrefix("defrost.divider.") else { return nil }
                return String(ident.dropFirst("defrost.divider.".count))
            }()

            let id: String
            if let dividerName {
                id = "defrost.divider.\(dividerName)"
            } else if let ident = ax.identifier, !ident.isEmpty {
                id = ident
            } else {
                let n = perAppIndex[ax.bundleID, default: 0]
                perAppIndex[ax.bundleID] = n + 1
                id = "\(ax.bundleID)#\(n)"
            }

            result.append(MenuBarItem(
                id: id,
                windowID: wid,
                frame: frame,
                windowOwnerPID: Bridging.ownerPID(of: wid) ?? ax.pid,
                appPID: ax.pid,
                bundleID: ax.bundleID,
                appName: ax.appName,
                label: ax.label,
                dividerName: dividerName
            ))
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func bestWindow(for axFrame: CGRect, in windows: [(CGWindowID, CGRect)], excluding used: Set<CGWindowID>) -> (CGWindowID, CGRect)? {
        var best: (CGWindowID, CGRect)?
        var bestScore: CGFloat = 0
        for (wid, frame) in windows where !used.contains(wid) {
            guard abs(frame.midY - axFrame.midY) < 30 else { continue }
            let overlap = min(frame.maxX, axFrame.maxX) - max(frame.minX, axFrame.minX)
            guard overlap > 0 else { continue }
            // Prefer windows of similar width (excludes the app menu bar window).
            let score = overlap / max(frame.width, axFrame.width)
            if score > bestScore {
                bestScore = score
                best = (wid, frame)
            }
        }
        return bestScore > 0.3 ? best : nil
    }

    private static func collectAXItems() -> [AXItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.processIdentifier > 0 }
        // Query apps in parallel, so one slow or hung app doesn't hold up the scan.
        var perApp = [[AXItem]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let found = axItems(for: apps[index])
            lock.lock(); perApp[index] = found; lock.unlock()
        }
        return perApp.flatMap { $0 }
    }

    private static func axItems(for app: NSRunningApplication) -> [AXItem] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        guard let bar: AXUIElement = attribute(appElement, "AXExtrasMenuBar"),
              let children: [AXUIElement] = attribute(bar, kAXChildrenAttribute) else { return [] }

        let bundleID = app.bundleIdentifier ?? app.executableURL?.lastPathComponent ?? "pid\(pid)"
        let appName = app.localizedName ?? bundleID
        var items: [AXItem] = []
        for child in children {
            guard let frame = frame(of: child), frame.width > 0, frame.height > 0 else { continue }
            let identifier: String? = attribute(child, "AXIdentifier")
            let desc: String? = attribute(child, kAXDescriptionAttribute)
            let title: String? = attribute(child, kAXTitleAttribute)
            let help: String? = attribute(child, kAXHelpAttribute)
            let label = [desc, title, help].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            items.append(AXItem(pid: pid, bundleID: bundleID, appName: appName, identifier: identifier, label: label, frame: frame))
        }
        return items
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }
}

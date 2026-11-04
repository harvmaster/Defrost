import AppKit
import ServiceManagement

/// Owns the dividers, the reveal state and everything that reacts to config changes.
///
/// While idle Defrost has no timers, no polling and no event monitors. The
/// only things that can wake it are a click on a divider, the hotkey, a
/// config file change, an app launch or system wake.
@MainActor
final class MenuBarController {
    let store: ConfigStore
    let reconciler = Reconciler()
    private(set) var dividerA: Divider!
    private(set) var dividerN: Divider!

    private(set) var isRevealed = false
    private var clickMonitor: Any?
    private var lastToggle = Date.distantPast
    private var rehideTimer: Timer?
    private var hotkey: Hotkey?
    private var trustTimer: Timer?


    var config: Config { store.config }

    init(store: ConfigStore) {
        self.store = store
    }

    func start() {
        // Creation order matters: a new status item appears left of existing
        // ones, so creating A first and then N gives [N][A][items...].
        dividerA = Divider(name: "A")
        dividerN = Divider(name: "N")
        // On macOS 26 clicks on empty menu bar space don't reach the expanded
        // divider, so a click-only global monitor handles them (see
        // handleClick). The divider actions stay as a fallback.
        dividerA.onClick = { [weak self] in self?.toggleDebounced() }
        dividerN.onClick = { [weak self] in self?.toggleDebounced() }
        applyDividerState()
        ItemMover.enableBackgroundCursorControl()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Cmd-clicks are menu bar rearranging, including Defrost's own synthetic moves.
            if event.modifierFlags.contains(.command) { return }
            if self?.reconciler.isRunning == true { return }
            let point = NSEvent.mouseLocation
            let isLeft = event.type == .leftMouseDown
            MainActor.assumeIsolated { self?.handleClick(at: point, isLeft: isLeft) }
        }

        reconciler.configProvider = { [weak self] in self?.store.config ?? Config() }
        reconciler.adoptAsAlways = store.isFirstRun
        reconciler.didScan = { [weak self] snapshot in
            guard let self else { return }
            reconciler.adoptAsAlways = false
            if snapshot.config != store.config {
                store.save(snapshot.config)
            }
        }

        store.onExternalChange = { [weak self] newConfig in
            Log.info("config.json changed on disk")
            self?.configDidChange(newConfig, reconcile: true)
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // Apps create their status items a little after launching.
            MainActor.assumeIsolated { self?.scheduleReconcile(after: [1.5, 5]) }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconcile(after: [2]) }
        }

        applyHotkey()
        applyLaunchAtLogin()
        ensureAccessibility()
        // Let the dividers settle before the first scan.
        scheduleReconcile(after: [0.2])
    }

    func stop() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        dividerA?.remove()
        dividerN?.remove()
    }

    // MARK: Config

    /// Called by the Settings window.
    func update(_ newConfig: Config) {
        guard newConfig != store.config else { return }
        store.save(newConfig)
        configDidChange(newConfig, reconcile: true)
    }

    private func configDidChange(_ newConfig: Config, reconcile: Bool) {
        applyHotkey()
        applyLaunchAtLogin()
        if reconcile { reconciler.reconcile() }
    }

    func rescan() {
        reconciler.reconcile()
    }

    private func scheduleReconcile(after delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reconciler.reconcile()
            }
        }
    }

    private func applyHotkey() {
        let wanted = store.config.hotkey ?? ""
        guard hotkey?.spec ?? "" != wanted || (hotkey == nil && !wanted.isEmpty) else { return }
        hotkey = nil
        if let spec = store.config.hotkey, !spec.isEmpty {
            hotkey = Hotkey(spec) { [weak self] in
                DispatchQueue.main.async { self?.toggle() }
            }
            if hotkey == nil { Log.info("could not register hotkey '\(spec)'") }
        }
    }

    private func applyLaunchAtLogin() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if store.config.launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !store.config.launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            Log.info("launch at login: \(error)")
        }
    }

    private func ensureAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard !AXIsProcessTrustedWithOptions(opts) else { return }
        // Polls only until permission is granted, then stops for good.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            MainActor.assumeIsolated {
                self?.trustTimer = nil
                self?.reconciler.reconcile()
            }
        }
    }

    // MARK: Reveal / hide

    func toggle() {
        isRevealed ? hide() : reveal()
    }

    func reveal() {
        guard !isRevealed else { return }
        isRevealed = true
        applyDividerState()
        installRehideTriggers()
    }

    func hide() {
        guard isRevealed else { return }
        isRevealed = false
        removeRehideTriggers()
        applyDividerState()
    }

    private func applyDividerState() {
        guard let dividerA, let dividerN else { return }
        dividerA.set(isRevealed ? .collapsed : .expanded)
        dividerN.set(.expanded)
    }

    private func installRehideTriggers() {
        scheduleRehideTimer(after: store.config.autoRehideSeconds)
    }

    private func removeRehideTriggers() {
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    private func toggleDebounced() {
        guard Date().timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = Date()
        toggle()
    }

    /// Runs once per mouse click anywhere, with no mouse-move tracking.
    /// Clicks outside the menu bar return after a single comparison, unless items are revealed.
    private func handleClick(at point: NSPoint, isLeft: Bool) {
        if let screen = NSScreen.screens.first(where: { MenuBarGeometry.isInMenuBar(point, on: $0) }) {
            guard isLeft else { return }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let empty = MenuBarGeometry.isEmptyMenuBarSpace(cgPoint)
                Log.info("menu bar click at \(Int(cgPoint.x)) empty=\(empty)")
                guard empty else { return }
                DispatchQueue.main.async { self?.toggleDebounced() }
            }
            return
        }
        guard isRevealed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.handleOutsideClick(at: point)
        }
    }

    private func scheduleRehideTimer(after seconds: TimeInterval) {
        rehideTimer?.invalidate()
        guard seconds > 0 else { return }
        rehideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRevealed else { return }
                // Don't pull an item out from under its open menu or popover.
                if WindowProbe.isMenuOrPopoverOpen() {
                    self.scheduleRehideTimer(after: 2)
                } else {
                    self.hide()
                }
            }
        }
    }

    private func handleOutsideClick(at point: NSPoint) {
        guard isRevealed else { return }
        // A click inside a menu or popover is the user using a revealed item.
        if WindowProbe.isMenuOrPopover(at: point) { return }
        hide()
    }
}

enum MenuBarGeometry {
    /// Whether an AppKit-coordinate point is inside the menu bar strip of `screen`.
    static func isInMenuBar(_ point: NSPoint, on screen: NSScreen) -> Bool {
        let f = screen.frame
        guard point.x >= f.minX, point.x <= f.maxX, point.y <= f.maxY else { return false }
        let inset = f.maxY - screen.visibleFrame.maxY
        let height = inset > 0 ? inset : NSStatusBar.system.thickness
        return point.y >= f.maxY - height
    }

    /// Whether a global (top-left origin) point in the menu bar is over neither
    /// a status item nor the frontmost app's menus. Runs off the main thread,
    /// and only for clicks inside the menu bar.
    static func isEmptyMenuBarSpace(_ point: CGPoint) -> Bool {
        for wid in Bridging.menuBarWindowIDs() {
            guard let f = Bridging.frame(of: wid), f.contains(point) else { continue }
            // The app menu bar window spans the full width, and expanded
            // dividers are thousands of points wide. Neither is an item.
            if f.width >= 1000 { continue }
            return false
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return true }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef else { return true }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef)
        var menusMaxX: CGFloat = 0
        for child in (childrenRef as? [AXUIElement]) ?? [] {
            var posRef: CFTypeRef?, sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success else { continue }
            var pos = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            menusMaxX = max(menusMaxX, pos.x + size.width)
        }
        return point.x > menusMaxX
    }
}

/// Window queries used only when a decision is needed, never on a timer.
enum WindowProbe {
    private static func onScreenWindows() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    static func isMenuOrPopoverOpen() -> Bool {
        onScreenWindows().contains { ($0[kCGWindowLayer as String] as? Int ?? 0) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }

    /// Whether the topmost window at `point` (AppKit coordinates) is a menu,
    /// popover or other floating panel rather than a normal window.
    static func isMenuOrPopover(at point: NSPoint) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        for info in onScreenWindows() {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(cgPoint) else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha == 0 { continue }
            return layer > 0 && layer < Int(CGWindowLevelForKey(.screenSaverWindow))
        }
        return false
    }
}

// LICENSE NOTE: The approach in this file, and the private API it calls, are
// adapted from Ice 2 (https://github.com/teddychan/ice-2-macos, GPL-3.0):
// Ice/MenuBar/Native/NativeMenuBarBridge.m, NativeMenuBarPolicy.swift and
// NativeMenuBarManager.swift. Ice 2 credits the research to
// https://github.com/fif7y/pelmet (GPL-3.0). Remove or rewrite this file to
// relicense Defrost away from the GPL.

import AppKit
import Darwin

/// Hides menu bar items on macOS 27 and later.
///
/// macOS 27 draws the whole menu bar in MenuBarAgent, and the divider trick
/// used on earlier versions no longer works. Instead, Defrost uses the
/// menu bar's "assessment mode" (the restricted mode used for exams), from the
/// private MenuBarClientCore framework. While an `MBAssessmentModeAssertion`
/// is held, MenuBarAgent shows only the system items and apps the assertion
/// allows, and hides everything else.
///
/// Hiding is therefore per app: all of an app's items are shown or hidden
/// together. Of Apple's own items, only the ones in `systemNames` can be
/// controlled; the clock and Control Centre always stay.
enum NativeMenuBar {
    /// MenuBarAgent's numbering for the system items that assessment mode can show or hide.
    static let systemNames = ["Battery", "Bluetooth", "Clock", "Displays", "Keyboard", "Sound", "Wi-Fi", "Screen Mirroring", "Control Centre"]
    static let clockSystemItem = 2
    static let controlCentreSystemItem = 8
    static let allSystemItems = Array(0...8)

    /// The system item number for a `com.apple.menuextra.*` identifier, if
    /// assessment mode can hide it.
    static func systemItem(forIdentifier identifier: String) -> Int? {
        guard identifier.hasPrefix("com.apple.menuextra.") else { return nil }
        let suffix = identifier.dropFirst("com.apple.menuextra.".count).lowercased()
        let number: Int? = [
            "battery": 0, "bluetooth": 1, "display": 3, "displays": 3,
            "keyboard": 4, "sound": 5, "volume": 5, "wifi": 6,
            "screen-mirroring": 7, "screenmirroring": 7,
        ][suffix]
        return number
    }

    // MARK: Policy

    /// macOS 27+ hides whole apps, and only those with a bundle ID; of
    /// Apple's own items only the ones in `NativeMenuBar.systemNames` can go.
    static func canHide(_ entry: ItemConfig) -> Bool {
        if entry.id.hasPrefix("com.apple.menuextra.") {
            return NativeMenuBar.systemItem(forIdentifier: entry.id) != nil
        }
        guard let bundle = entry.bundleID, bundle.contains("."),
              !["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver", Bundle.main.bundleIdentifier]
                .contains(bundle) else { return false }
        return true
    }

    /// What the assertion should allow. nil means nothing needs hiding, so no assertion is held.
    struct Configuration: Equatable {
        let systemItems: [Int]
        let bundles: [String]
    }

    /// Works out what to allow from the config.
    ///
    /// - An app's policy is the most visible policy among its items, so nothing
    ///   is hidden that the config says should show.
    /// - Apps that aren't in the config yet stay visible. The reconciler then
    ///   finds their items and adds them with the default policy.
    static func configuration(for config: Config, runningBundles: Set<String>, revealed: Bool) -> Configuration? {
        func hides(_ policy: Policy) -> Bool {
            switch policy {
            case .always: false
            case .focused: !revealed
            case .never: true
            }
        }

        var bundlePolicy: [String: Policy] = [:]
        var systemPolicy: [Int: Policy] = [:]
        for entry in config.items {
            if let number = systemItem(forIdentifier: entry.id) {
                systemPolicy[number] = mostVisible(systemPolicy[number], entry.policy)
            } else if let bundle = entry.bundleID {
                bundlePolicy[bundle] = mostVisible(bundlePolicy[bundle], entry.policy)
            }
        }

        let own = Bundle.main.bundleIdentifier
        let hiddenBundles = Set(bundlePolicy.filter { hides($0.value) && $0.key != own }.keys)
        let hiddenSystem = Set(systemPolicy.filter { hides($0.value) }.keys)
            .subtracting([clockSystemItem, controlCentreSystemItem])

        // Holding the assertion has side effects (see `NotificationCenterBridge`),
        // so only hold it when something running actually needs hiding.
        guard !hiddenBundles.isDisjoint(with: runningBundles) || !hiddenSystem.isEmpty else { return nil }

        var allowed = runningBundles.subtracting(hiddenBundles)
        if let own { allowed.insert(own) }
        return Configuration(
            systemItems: allSystemItems.filter { !hiddenSystem.contains($0) },
            bundles: allowed.sorted()
        )
    }

    private static func mostVisible(_ a: Policy?, _ b: Policy) -> Policy {
        guard let a else { return b }
        func rank(_ p: Policy) -> Int {
            switch p {
            case .never: 0
            case .focused: 1
            case .always: 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }

    // MARK: Private API bridge

    private static let framework: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY)

    private static let configurationInit = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
    private static let activateSelector = NSSelectorFromString("activateWithConfiguration:completionHandler:")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    /// Whether this macOS has the assessment mode API, with the shape Defrost expects.
    static let isAvailable: Bool = {
        guard framework != nil,
              let configurationClass = NSClassFromString("MBAssessmentModeConfiguration"),
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") else { return false }
        return class_getInstanceMethod(configurationClass, configurationInit) != nil
            && class_getInstanceMethod(assertionClass, activateSelector) != nil
            && class_getInstanceMethod(assertionClass, invalidateSelector) != nil
    }()

    /// Starts hiding. Returns the assertion, which hides until it is invalidated.
    /// `completion` is called on an arbitrary queue once MenuBarAgent has applied it.
    static func activate(_ configuration: Configuration, completion: @escaping (Error?) -> Void) -> NSObject? {
        guard isAvailable,
              let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              let assertionClass = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let initIMP = class_getMethodImplementation(configurationClass, configurationInit),
              let activateIMP = class_getMethodImplementation(assertionClass, activateSelector),
              let allocated = configurationClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }

        typealias InitFunction = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject?
        typealias ActivateFunction = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSError?) -> Void) -> Void

        let systemItems = configuration.systemItems.map { NSNumber(value: $0) } as NSArray
        guard let mbConfiguration = unsafeBitCast(initIMP, to: InitFunction.self)(
            allocated, configurationInit, systemItems, configuration.bundles as NSArray) else { return nil }
        let assertion = assertionClass.init()
        unsafeBitCast(activateIMP, to: ActivateFunction.self)(assertion, activateSelector, mbConfiguration) { error in
            completion(error)
        }
        return assertion
    }

    static func invalidate(_ assertion: NSObject?) {
        guard let assertion, assertion.responds(to: invalidateSelector) else { return }
        assertion.perform(invalidateSelector)
    }
}

extension ItemConfig {
    /// The app that owns this item, for hiding on macOS 27. Item IDs are
    /// either "<bundle>#<n>" or an Accessibility identifier; for the latter
    /// the bundle is stored separately.
    var bundleID: String? {
        if let bundle { return bundle }
        if id.hasPrefix("com.apple.menuextra.") { return nil }
        guard let hash = id.lastIndex(of: "#") else { return nil }
        return String(id[..<hash])
    }
}

/// Holds the assertion and swaps it as the wanted configuration changes.
///
/// Adapted from Ice 2's `NativeMenuBarManager.apply` (GPL-3.0): the previous
/// assertion stays in force until its replacement is active, so items that
/// should stay hidden never flash on screen during a change.
@MainActor
final class NativeHider {
    private var assertion: NSObject?
    private var pendingAssertion: NSObject?
    private(set) var configuration: NativeMenuBar.Configuration?
    private var generation = 0
    private var timeout: DispatchWorkItem?

    /// True while an assertion is hiding items, or about to.
    var isConcealing: Bool { assertion != nil || pendingAssertion != nil }

    func apply(_ desired: NativeMenuBar.Configuration?) {
        guard desired != configuration else { return }
        guard let desired else {
            restore()
            return
        }
        generation += 1
        let request = generation
        timeout?.cancel()
        NativeMenuBar.invalidate(pendingAssertion)
        configuration = desired
        pendingAssertion = NativeMenuBar.activate(desired) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == request else { return }
                    self.timeout?.cancel()
                    if let error {
                        Log.info("menu bar hiding failed: \(error.localizedDescription)")
                        self.restore()
                    } else {
                        NativeMenuBar.invalidate(self.assertion)
                        self.assertion = self.pendingAssertion
                        self.pendingAssertion = nil
                    }
                }
            }
        }
        guard pendingAssertion != nil else {
            Log.info("menu bar hiding is unavailable on this version of macOS")
            restore()
            return
        }
        // Fail open: if MenuBarAgent never answers, show everything rather than
        // leave items hidden with no way to reveal them.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == request else { return }
                Log.info("menu bar hiding timed out")
                self.restore()
            }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Shows everything. Also used before sleep and on quit.
    func restore() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        NativeMenuBar.invalidate(assertion)
        NativeMenuBar.invalidate(pendingAssertion)
        assertion = nil
        pendingAssertion = nil
        configuration = nil
    }
}

/// macOS 27+: works around Notification Center not opening while items are hidden.
///
/// While an assessment-mode assertion is held, clicking the clock and the
/// "Show Notification Center" shortcut do nothing. This watches for those two
/// gestures with a listen-only event tap, releases the assertion, replays the
/// gesture, and keeps hidden items shown until the panel closes. The trackpad
/// gesture can't be detected and isn't bridged.
///
/// Adapted from Ice 2's Notification Center bridge in NativeMenuBarManager.swift (GPL-3.0).
@MainActor
final class NotificationCenterBridge {
    /// Marks events the bridge posts, so its own tap ignores them.
    private static let replayMarker: Int64 = 0x0DEF_0C0C
    private static let clockIdentifier = "com.apple.menuextra.clock"
    private static let notificationCenterBundle = "com.apple.notificationcenterui"
    /// The `com.apple.symbolichotkeys` entry for "Show Notification Center".
    private static let showNotificationCenterHotKey = "163"

    private enum Gesture {
        case click(CGPoint)
        case key(CGKeyCode, CGEventFlags)
    }

    private let isConcealing: () -> Bool
    private let suspend: (Bool) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// True from a bridged gesture until Notification Center closes.
    private(set) var isSuspended = false
    private var watch: Task<Void, Never>?

    /// - Parameters:
    ///   - isConcealing: whether items are currently hidden.
    ///   - suspend: called with true to show everything, and false to hide again.
    init(isConcealing: @escaping () -> Bool, suspend: @escaping (Bool) -> Void) {
        self.isConcealing = isConcealing
        self.suspend = suspend
        installTap()
    }

    func stop() {
        watch?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func installTap() {
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let bridge = Unmanaged<NotificationCenterBridge>.fromOpaque(refcon).takeUnretainedValue()
                // The tap's source is on the main run loop.
                MainActor.assumeIsolated { bridge.handle(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }
        // Listen only: the gestures do nothing while hidden, so there's nothing
        // to swallow, and a filtering tap would delay every event on the system.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.info("Notification Center bridge: could not create the event tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard !isSuspended, isConcealing(),
              event.getIntegerValueField(.eventSourceUserData) != Self.replayMarker else { return }
        switch type {
        case .leftMouseDown:
            let location = event.location
            if isInMenuBar(location), isClock(at: location) {
                suspend(replaying: .click(location))
            }
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let hotKey = Self.notificationCenterHotKey() else { return }
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            if keyCode == hotKey.keyCode, event.flags.intersection(relevant) == hotKey.flags.intersection(relevant) {
                suspend(replaying: .key(keyCode, hotKey.flags.intersection(relevant)))
            }
        default:
            break
        }
    }

    /// Cheap check so the Accessibility hit test only runs for menu bar clicks.
    private func isInMenuBar(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { display in
            let bounds = CGDisplayBounds(display)
            return point.x >= bounds.minX && point.x < bounds.maxX
                && point.y >= bounds.minY && point.y < bounds.minY + 60
        }
    }

    /// A click can land on the clock or on the padding of the group that holds it.
    private func isClock(at point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        var candidates = [hit]
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(hit, kAXChildrenAttribute as CFString, &children) == .success,
           let list = children as? [AXUIElement] {
            candidates += list
        }
        return candidates.contains { element in
            var identifier: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier) == .success else { return false }
            return identifier as? String == Self.clockIdentifier
        }
    }

    /// The user's "Show Notification Center" shortcut, if one is set and enabled.
    private static func notificationCenterHotKey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard let hotKeys = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = hotKeys[showNotificationCenterHotKey] as? [String: Any],
              (entry["enabled"] as? Bool) == true || (entry["enabled"] as? Int) == 1,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              parameters[1] != 65535 else { return nil }
        return (CGKeyCode(parameters[1]), CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    private func suspend(replaying gesture: Gesture) {
        isSuspended = true
        suspend(true)
        watch?.cancel()
        watch = Task { [weak self] in
            // MenuBarAgent needs a moment after the release before the gesture works.
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            self.replay(gesture)
            await self.waitForNotificationCenterToClose()
            guard !Task.isCancelled else { return }
            self.isSuspended = false
            self.suspend(false)
        }
    }

    private func replay(_ gesture: Gesture) {
        // Session tap, not the HID tap: posting modifier flags at the HID level
        // can leave a modifier stuck down system-wide.
        let source = CGEventSource(stateID: .combinedSessionState)
        var events: [CGEvent?] = []
        switch gesture {
        case .click(let point):
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.flags = []
                events.append(event)
            }
        case .key(let keyCode, let flags):
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
                event?.flags = flags
                events.append(event)
            }
        }
        for event in events.compactMap({ $0 }) {
            event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Waits up to two seconds for the panel to open, then for as long as it stays open.
    private func waitForNotificationCenterToClose() async {
        var opened = false
        let deadline = ContinuousClock.now + .seconds(2)
        while !Task.isCancelled {
            let open = Self.isNotificationCenterOpen()
            if open { opened = true }
            if opened ? !open : ContinuousClock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func isNotificationCenterOpen() -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: notificationCenterBundle).map(\.processIdentifier))
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        // The panel is a large window above normal levels; the desktop widgets
        // from the same process sit at a negative level.
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Height"] ?? 0) > 200
        }
    }
}

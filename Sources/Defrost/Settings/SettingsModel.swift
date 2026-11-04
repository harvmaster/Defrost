import AppKit
import Combine

@MainActor
final class SettingsModel: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var isTrusted = AXIsProcessTrusted()
    @Published private(set) var isIceRunning = false

    /// Settings runs in its own short-lived process. It talks to the
    /// background Defrost process only through config.json, which that
    /// process watches and applies.
    private let store: ConfigStore

    init(store: ConfigStore) {
        self.store = store
        self.config = store.config
        store.onExternalChange = { [weak self] newConfig in
            self?.configChanged(newConfig)
        }
        scan()
    }

    /// Lists the current menu bar items and adds any new ones to the config.
    func scan() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard AXIsProcessTrusted() else {
                DispatchQueue.main.async { self?.refreshEnvironment() }
                return
            }
            let items = MenuBarItems.current()
            DispatchQueue.main.async {
                guard let self else { return }
                self.items = items
                self.refreshEnvironment()
                var c = self.store.config
                Reconciler.adopt(items: items, into: &c)
                if c != self.store.config { self.commit(c) }
            }
        }
    }

    func refreshEnvironment() {
        isTrusted = AXIsProcessTrusted()
        isIceRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.jordanbaird.Ice").isEmpty
    }

    func configChanged(_ config: Config) {
        if self.config != config { self.config = config }
    }

    private func commit(_ newConfig: Config) {
        config = newConfig
        store.save(newConfig)
    }

    // MARK: Rows

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let policy: Policy
        let isPresent: Bool
        let icon: NSImage?

        static func == (a: Row, b: Row) -> Bool {
            a.id == b.id && a.name == b.name && a.policy == b.policy && a.isPresent == b.isPresent
        }
    }

    func rows(for policy: Policy) -> [Row] {
        let present = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return config.items.filter { $0.policy == policy }.map { entry in
            let live = present[entry.id]
            return Row(
                id: entry.id,
                name: live?.displayName ?? entry.name,
                policy: entry.policy,
                isPresent: live != nil,
                icon: icon(for: entry.id, live: live)
            )
        }
    }

    /// Small rasterised icons, owned by this model, so they are freed when Settings closes.
    private var iconCache: [String: NSImage] = [:]

    private func icon(for id: String, live: MenuBarItem?) -> NSImage? {
        let bundleID = live?.bundleID ?? String(id.split(separator: "#").first ?? Substring(id))
        if let cached = iconCache[bundleID] { return cached }
        var image: NSImage?
        if let pid = live?.appPID, let app = NSRunningApplication(processIdentifier: pid) {
            image = app.icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        if id.hasPrefix("com.apple.menuextra."),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.controlcenter") {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        guard let source = image else { return nil }
        let thumbnail = Self.thumbnail(source, points: 18)
        iconCache[bundleID] = thumbnail
        return thumbnail
    }

    /// Draws into a 2x bitmap, so the full-size (up to 1024 px) icon representations aren't kept.
    private static func thumbnail(_ image: NSImage, points: CGFloat) -> NSImage {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: points, height: points))
        result.addRepresentation(rep)
        return result
    }

    // MARK: Edits

    func setPolicy(_ policy: Policy, for id: String) {
        var c = config
        guard let index = c.items.firstIndex(where: { $0.id == id }), c.items[index].policy != policy else { return }
        var entry = c.items.remove(at: index)
        let movingRight = Self.rank(policy) > Self.rank(entry.policy)
        entry.policy = policy
        // Put the item on the side of its new group nearest its old position,
        // so it only has to cross one divider.
        if movingRight {
            if let first = c.items.firstIndex(where: { $0.policy == policy }) {
                c.items.insert(entry, at: first)
            } else {
                c.items.append(entry)
            }
        } else {
            if let last = c.items.lastIndex(where: { $0.policy == policy }) {
                c.items.insert(entry, at: last + 1)
            } else {
                c.items.append(entry)
            }
        }
        commit(c)
    }

    private static func rank(_ p: Policy) -> Int {
        switch p {
        case .never: 0
        case .focused: 1
        case .always: 2
        }
    }

    func move(in policy: Policy, from source: IndexSet, to destination: Int) {
        var c = config
        var group = c.items.filter { $0.policy == policy }
        group.move(fromOffsets: source, toOffset: destination)
        var iterator = group.makeIterator()
        c.items = c.items.map { $0.policy == policy ? iterator.next()! : $0 }
        commit(c)
    }

    func forget(_ id: String) {
        var c = config
        c.items.removeAll { $0.id == id }
        commit(c)
    }

    func setDefaultPolicy(_ p: Policy) { var c = config; c.defaultPolicy = p; commit(c) }
    func setAutoRehide(_ s: Double) { var c = config; c.autoRehideSeconds = max(0, s); commit(c) }
    func setHotkey(_ h: String?) { var c = config; c.hotkey = h; commit(c) }
    func setLaunchAtLogin(_ v: Bool) { var c = config; c.launchAtLogin = v; commit(c) }

    func rescan() { scan() }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Quits the background agent as well as this Settings process.
    func quitDefrost() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.processIdentifier != me {
            app.terminate()
        }
        NSApp.terminate(nil)
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.file])
    }
}

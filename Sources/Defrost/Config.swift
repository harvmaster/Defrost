import Foundation

enum Policy: String, Codable, CaseIterable, Identifiable {
    case always, focused, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: "Always"
        case .focused: "Focused"
        case .never: "Never"
        }
    }
    var subtitle: String {
        switch self {
        case .always: "Always visible in the menu bar"
        case .focused: "Shown when you click empty menu bar space"
        case .never: "Never shown"
        }
    }
}

struct ItemConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var policy: Policy
}

/// The whole configuration. Within each policy group, `items` are listed
/// left-to-right as they appear in the menu bar.
struct Config: Codable, Equatable {
    var defaultPolicy: Policy = .focused
    /// Seconds before revealed items hide again. 0 disables the timeout.
    var autoRehideSeconds: Double = 15
    /// e.g. "ctrl+opt+space". nil or empty disables the hotkey.
    var hotkey: String? = "ctrl+opt+space"
    var launchAtLogin: Bool = false
    var items: [ItemConfig] = []

    init() {}

    // Tolerant decoding so hand-edited files with missing keys still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        defaultPolicy = try c.decodeIfPresent(Policy.self, forKey: .defaultPolicy) ?? d.defaultPolicy
        autoRehideSeconds = try c.decodeIfPresent(Double.self, forKey: .autoRehideSeconds) ?? d.autoRehideSeconds
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        items = try c.decodeIfPresent([ItemConfig].self, forKey: .items) ?? []
    }

    func policy(for id: String) -> Policy? {
        items.first { $0.id == id }?.policy
    }
}

/// Loads and saves `~/.config/defrost/config.json` and watches it for
/// external edits. The watcher is a kqueue vnode source, so it costs nothing
/// until the directory actually changes.
final class ConfigStore {
    static let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/defrost", isDirectory: true)
    static let file = directory.appendingPathComponent("config.json")

    /// The real file, if config.json (or the directory) is a symlink, for
    /// example into a dotfiles repo. Saving and watching use this, so links are never replaced.
    static var resolvedFile: URL { file.resolvingSymlinksInPath() }

    private(set) var config = Config()
    private(set) var isFirstRun = false
    var onExternalChange: ((Config) -> Void)?

    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let loaded = Self.read() {
            config = loaded
        } else if !FileManager.default.fileExists(atPath: Self.file.path) {
            isFirstRun = true
            save(config)
        } else {
            Log.info("config.json is invalid; using defaults in memory until it is fixed")
        }
        startWatching()
    }

    private static func read() -> Config? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save(_ newConfig: Config) {
        config = newConfig
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(newConfig) else { return }
        // Skip identical writes, so a synced or version-controlled copy doesn't churn.
        let target = Self.resolvedFile
        if let existing = try? Data(contentsOf: target), existing == data { return }
        try? data.write(to: target, options: .atomic)
    }

    /// Watches the directory (for atomic saves that replace the file) and the
    /// file itself (for in-place writes). Both are kqueue sources with no polling.
    private func startWatching() {
        dirSource = watch(path: Self.resolvedFile.deletingLastPathComponent().path, events: [.write, .rename, .delete]) { [weak self] in
            self?.rewatchFile()
            self?.scheduleReload()
        }
        rewatchFile()
    }

    private func rewatchFile() {
        fileSource?.cancel()
        fileSource = watch(path: Self.resolvedFile.path, events: [.write, .extend, .rename, .delete]) { [weak self] in
            self?.scheduleReload()
        }
    }

    private func watch(path: String, events: DispatchSource.FileSystemEvent, handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let loaded = Self.read(), loaded != self.config else { return }
            self.config = loaded
            self.onExternalChange?(loaded)
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

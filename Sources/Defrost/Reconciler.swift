import AppKit

/// Makes the menu bar match the config.
///
/// Target layout, left to right:
///   [Never items] |N| [Focused items] |A| [Always items] [fixed: Control Center, clock]
///
/// Only items outside the longest run that is already in the right relative
/// order get moved, so a typical reconcile touches 0–2 items.
final class Reconciler {
    struct Snapshot {
        var items: [MenuBarItem]
        var config: Config
    }

    private let queue = DispatchQueue(label: "defrost.reconcile", qos: .userInitiated)
    private var pending = false
    private var running = false
    var isRunning: Bool { running }
    /// Set on first run: adopt every existing item as Always.
    var adoptAsAlways = false

    /// Called on the main thread with the scan result and an updated config
    /// (new items added with the default policy).
    var didScan: ((Snapshot) -> Void)?
    /// Supplies the current config. Called on the main thread.
    var configProvider: (() -> Config)?

    /// Queues a reconcile. Calls made while one is running are coalesced into a single follow-up.
    func reconcile(applyMoves: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AXIsProcessTrusted() else { return }
        if running { pending = true; return }
        running = true
        let config = configProvider?() ?? Config()
        queue.async { [weak self] in
            self?.run(config: config, applyMoves: applyMoves)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                if self.pending {
                    self.pending = false
                    self.reconcile(applyMoves: applyMoves)
                }
            }
        }
    }

    private func run(config inputConfig: Config, applyMoves: Bool) {
        let scanStart = Date()
        let items = MenuBarItems.current()
        Log.info("scan: \(items.count) items in \(Int(Date().timeIntervalSince(scanStart) * 1000)) ms")
        var config = inputConfig
        Reconciler.adopt(items: items, into: &config, firstRun: adoptAsAlways)
        DispatchQueue.main.sync { didScan?(Snapshot(items: items, config: config)) }
        // macOS 27+ hides whole apps with assessment mode (see NativeMenuBar),
        // so items are never moved there; the scan only adds new items.
        guard applyMoves, !MenuBarItems.isComposited else { return }

        let movable = items.filter { !$0.isFixed }
        guard movable.contains(where: { $0.dividerName == "A" }),
              movable.contains(where: { $0.dividerName == "N" }) else {
            Log.info("dividers not found in menu bar; skipping reconcile")
            return
        }

        let target = Reconciler.targetOrder(movable: movable, config: config)
        let currentIDs = movable.map(\.id)
        guard currentIDs != target else { return }

        // Moves work on hidden (off-screen) items, so nothing is revealed.
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let current = items.filter { !$0.isFixed }.map(\.id).filter { target.contains($0) }
        let leftmostFixed = items.filter(\.isFixed).min { $0.frame.minX < $1.frame.minX }
        let keep = Reconciler.longestOrderedSubsequence(current, order: target)
        let toMove = target.filter { !keep.contains($0) }
        Log.info("reconcile: moving \(toMove.count) item(s): \(toMove.joined(separator: ", "))")
        let started = Date()
        defer { Log.info("reconcile: done in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }

        // Walk the target right to left. Each item not in `keep` is dropped to
        // the left of its right-hand neighbour, which is already correct.
        for (index, id) in target.enumerated().reversed() where !keep.contains(id) {
            guard let item = byID[id] else { continue }
            do {
                if index + 1 < target.count, let neighbour = byID[target[index + 1]] {
                    try ItemMover.move(item, to: .leftOf(neighbour))
                } else if let leftmostFixed {
                    try ItemMover.move(item, to: .leftOf(leftmostFixed))
                } else if index > 0, let neighbour = byID[target[index - 1]] {
                    try ItemMover.move(item, to: .rightOf(neighbour))
                }
            } catch {
                Log.info("could not move \(id): \(error)")
            }
            usleep(40_000)
        }
    }

    /// Adds items that are missing from the config. On first run everything
    /// is adopted as Always, so nothing disappears until the user chooses.
    static func adopt(items: [MenuBarItem], into config: inout Config, firstRun: Bool = false) {
        let known = Set(config.items.map(\.id))
        for item in items where !item.isDivider && !item.isFixed && !known.contains(item.id) {
            var policy = firstRun ? .always : config.defaultPolicy
            // macOS 27 hides an app's items together, so a new item joins its
            // app's existing policy.
            if MenuBarItems.isComposited,
               let sibling = config.items.first(where: { $0.bundleID == item.bundleID && !item.bundleID.isEmpty }) {
                policy = sibling.policy
            }
            var entry = ItemConfig(id: item.id, name: item.displayName, policy: policy)
            if !item.id.hasPrefix("\(item.bundleID)#") && !item.id.hasPrefix("com.apple.menuextra.") {
                entry.bundle = item.bundleID
            }
            // macOS 27+: items Defrost can't hide are always shown, so say so.
            if MenuBarItems.isComposited, !NativeMenuBar.canHide(entry) {
                entry.policy = .always
            }
            // New items start at the left end of their group.
            if let firstOfGroup = config.items.firstIndex(where: { $0.policy == entry.policy }) {
                config.items.insert(entry, at: firstOfGroup)
            } else {
                config.items.append(entry)
            }
        }
    }

    /// Target left-to-right order of the movable items currently present.
    static func targetOrder(movable: [MenuBarItem], config: Config) -> [String] {
        let present = Set(movable.map(\.id))
        func group(_ p: Policy) -> [String] {
            config.items.filter { $0.policy == p && present.contains($0.id) }.map(\.id)
        }
        return group(.never) + ["defrost.divider.N"] + group(.focused) + ["defrost.divider.A"] + group(.always)
    }

    /// The longest subsequence of `current` whose elements are already in the
    /// same relative order as in `order` (an LIS on target indexes).
    static func longestOrderedSubsequence(_ current: [String], order: [String]) -> Set<String> {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let seq = current.compactMap { id in rank[id].map { (id, $0) } }
        guard !seq.isEmpty else { return [] }
        var tails: [Int] = []          // indexes into seq
        var prev = [Int](repeating: -1, count: seq.count)
        for i in seq.indices {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if seq[tails[mid]].1 < seq[i].1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var result = Set<String>()
        var k = tails.last ?? -1
        while k >= 0 { result.insert(seq[k].0); k = prev[k] }
        return result
    }
}

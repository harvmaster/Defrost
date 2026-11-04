// LICENSE NOTE: The divider hiding technique (an expanded status item that
// pushes items off-screen) is adapted from Ice (https://github.com/jordanbaird/Ice,
// GPL-3.0). Used on macOS 14–26 only.

import AppKit

/// An invisible status item used as a section boundary.
///
/// - `expanded`: 10,000 pt wide. It pushes every item to its left off-screen
///   and fills the empty menu bar space, so clicks there reach it.
/// - `collapsed`: about 0 pt wide and invisible, but still in the menu bar,
///   so it keeps marking the boundary.
@MainActor
final class Divider {
    enum State { case expanded, collapsed }

    static let expandedLength: CGFloat = 10_000

    let name: String
    let statusItem: NSStatusItem
    private let widthConstraint: NSLayoutConstraint?
    var onClick: (() -> Void)?

    private(set) var state: State = .collapsed

    init(name: String) {
        self.name = name
        let autosaveName = "defrost-\(name)"
        // AppKit caches status item positions in UserDefaults. Defrost keeps
        // no state there: the cache is cleared and the reconciler places the
        // dividers from ~/.config/defrost on every launch.
        Divider.clearPositionCache(autosaveName: autosaveName)

        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        statusItem.autosaveName = autosaveName
        statusItem.behavior = []

        // Same approach as Ice (ControlItem.swift): find the private constraint
        // that stops status items from going below a minimum width, so the
        // divider can be made effectively invisible.
        if let button = statusItem.button,
           let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal) {
            widthConstraint = constraints.first { $0.secondItem === button.superview }
        } else {
            widthConstraint = nil
        }

        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            button.setAccessibilityIdentifier("defrost.divider.\(name)")
            button.setAccessibilityLabel("Defrost \(name) divider")
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        set(.collapsed)
    }

    static func clearPositionCache(autosaveName: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "NSStatusItem Preferred Position \(autosaveName)")
        defaults.removeObject(forKey: "NSStatusItem Visible \(autosaveName)")
    }

    func set(_ newState: State) {
        state = newState
        switch newState {
        case .expanded:
            widthConstraint?.isActive = true
            statusItem.length = Divider.expandedLength
        case .collapsed:
            statusItem.length = 0
            widthConstraint?.isActive = false
            if let window = statusItem.button?.window {
                var size = window.frame.size
                size.width = 1
                window.setContentSize(size)
            }
        }
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
        Divider.clearPositionCache(autosaveName: "defrost-\(name)")
    }

    @objc private func clicked() {
        onClick?()
    }
}

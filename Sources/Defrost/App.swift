import AppKit
import SwiftUI

/// Defrost runs as two kinds of process from the same binary:
///
/// - **Agent** (default): the long-lived, UI-less process that owns the
///   dividers. It never loads SwiftUI, which keeps it at about 20 MB.
/// - **Settings** (`--settings`): a short-lived process for the settings
///   window. It exits when the window closes, so its memory is fully freed.
///   It changes behaviour only by writing config.json, which the agent watches.
@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains(SettingsApp.flag) {
            let delegate = SettingsApp()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        } else {
            let delegate = AgentApp()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AgentApp: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var controller: MenuBarController!
    private var settingsProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.trimIfNeeded()
        Log.info("launch \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev")")
        store = ConfigStore()
        controller = MenuBarController(store: store)
        controller.start()

        if store.isFirstRun {
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        settingsProcess?.terminate()
        controller?.stop()
    }

    /// There is no menu bar icon, so opening the app again shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func openSettings() {
        if let running = settingsProcess, running.isRunning,
           let app = NSRunningApplication(processIdentifier: running.processIdentifier) {
            app.activate()
            return
        }
        guard let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = [SettingsApp.flag]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // Settings may have changed the layout, so reconcile once more to be safe.
                    self.settingsProcess = nil
                    self.controller.rescan()
                }
            }
        }
        do {
            try process.run()
            settingsProcess = process
        } catch {
            Log.info("could not open settings: \(error)")
        }
    }
}

@MainActor
final class SettingsApp: NSObject, NSApplicationDelegate {
    static let flag = "--settings"

    private var store: ConfigStore!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore()
        let model = SettingsModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Defrost"
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 560, height: 640))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

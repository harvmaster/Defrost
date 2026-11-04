import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            ItemsPane(model: model)
                .tabItem { Label("Menu Bar Items", systemImage: "menubar.rectangle") }
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 560)
        .onAppear { model.refreshEnvironment() }
    }
}

private struct Banners: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if !model.isTrusted {
            Banner(text: "Defrost needs Accessibility permission to find and move menu bar items.",
                   button: "Open Settings") { model.openAccessibilitySettings() }
        }
        if model.isIceRunning {
            Banner(text: "Ice is running. Quit it first, or the two apps will fight over the menu bar.",
                   button: nil, action: {})
        }
    }
}

private struct Banner: View {
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout)
            Spacer()
            if let button { Button(button, action: action) }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ItemsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Banners(model: model)
            List {
                ForEach(Policy.allCases) { policy in
                    Section {
                        let rows = model.rows(for: policy)
                        if rows.isEmpty {
                            Text("No items").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(rows) { row in
                            ItemRow(row: row, model: model)
                        }
                        // macOS 27+ can't rearrange the menu bar, so order doesn't matter there.
                        .onMove(perform: MenuBarItems.isComposited ? nil : { model.move(in: policy, from: $0, to: $1) })
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(policy.title).font(.headline)
                            Text(policy.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Text(MenuBarItems.isComposited
                     ? "On macOS 27, items are hidden per app, so all of an app's items share a policy. Hold ⌘ and drag items in the menu bar to arrange them."
                     : "Drag to reorder. Each list runs left to right as items appear in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { model.rescan() }
            }
        }
    }
}

private struct ItemRow: View {
    let row: SettingsModel.Row
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            if let icon = row.icon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                if !row.isPresent {
                    Text("Not running").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(row.isPresent ? 1 : 0.55)
            Spacer()
            Picker("", selection: Binding(
                get: { row.policy },
                set: { model.setPolicy($0, for: row.id) }
            )) {
                ForEach(Policy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .disabled(!row.canHide)
            .help(row.canHide ? "" : "macOS 27 doesn't let Defrost hide this item.")
        }
        .contextMenu {
            Button("Forget This Item") { model.forget(row.id) }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @State private var rehideText = ""

    var body: some View {
        Form {
            Section {
                Banners(model: model)
            }
            Section("Behaviour") {
                Picker("Policy for new items", selection: Binding(
                    get: { model.config.defaultPolicy },
                    set: { model.setDefaultPolicy($0) }
                )) {
                    ForEach(Policy.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("Hide Focused items again after")
                    Spacer()
                    TextField("", text: $rehideText)
                        .frame(width: 50)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { commitRehide() }
                    Text("seconds (0 = never)").foregroundStyle(.secondary)
                }
                HotkeyRecorder(spec: model.config.hotkey) { model.setHotkey($0) }
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.config.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                LabeledContent("Configuration") {
                    Button("Show config.json in Finder") { model.revealConfig() }
                }
                LabeledContent("Defrost") {
                    Button("Quit Defrost") { model.quitDefrost() }
                }
            }
            Section {
                Text("Defrost has no menu bar icon. Open it again from Spotlight or Finder to get back to these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { rehideText = Self.format(model.config.autoRehideSeconds) }
        .onChange(of: model.config.autoRehideSeconds) { _, v in rehideText = Self.format(v) }
        .onDisappear { commitRehide() }
    }

    private func commitRehide() {
        if let v = Double(rehideText.trimmingCharacters(in: .whitespaces)) {
            model.setAutoRehide(v)
        } else {
            rehideText = Self.format(model.config.autoRehideSeconds)
        }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

private struct HotkeyRecorder: View {
    let spec: String?
    let onChange: (String?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent("Show/hide Focused items hotkey") {
            HStack {
                Button(recording ? "Press keys…" : HotkeySpec.pretty(spec)) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 110)
                if spec != nil && !(spec ?? "").isEmpty {
                    Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Clear hotkey")
                }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                stop()
            } else if let new = HotkeySpec.from(event: event) {
                onChange(new)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

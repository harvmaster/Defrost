import AppKit
import Carbon.HIToolbox

/// A global hotkey registered through Carbon's RegisterEventHotKey. This
/// needs no permissions and costs nothing until the key combination is pressed.
final class Hotkey {
    private var ref: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private let action: () -> Void
    let spec: String

    /// Weak entries, so dropping a Hotkey unregisters it.
    private final class WeakBox { weak var hotkey: Hotkey?; init(_ h: Hotkey) { hotkey = h } }
    private static var registry: [UInt32: WeakBox] = [:]
    private static var nextID: UInt32 = 1
    private let hotkeyID: UInt32

    init?(_ spec: String, action: @escaping () -> Void) {
        guard let (keyCode, modifiers) = HotkeySpec.parse(spec) else { return nil }
        self.action = action
        self.spec = spec
        self.hotkeyID = Hotkey.nextID
        Hotkey.nextID += 1

        guard Hotkey.installHandlerOnce() else { return nil }

        let hkID = EventHotKeyID(signature: OSType(0x4446_5253), id: hotkeyID) // "DFRS"
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        Hotkey.registry[hotkeyID] = WeakBox(self)
    }

    /// One application-wide handler that dispatches on the hotkey ID.
    private static func installHandlerOnce() -> Bool {
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            Hotkey.registry[hkID.id]?.hotkey?.action()
            return noErr
        }, 1, &eventType, nil, &handlerRef)
        return status == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Hotkey.registry[hotkeyID] = nil
    }
}

/// Converts between strings like "ctrl+opt+space" and Carbon key codes and modifiers.
enum HotkeySpec {
    static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape,
        "delete": kVK_Delete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]

    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, let key = keys[keyName] else { return nil }
        var mods: UInt32 = 0
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "shift": mods |= UInt32(shiftKey)
            default: return nil
            }
        }
        guard mods != 0 else { return nil }
        return (UInt32(key), mods)
    }

    /// Builds a spec string from a key-down event, or nil if there is no modifier or the key is unknown.
    static func from(event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty,
              let name = keys.first(where: { $0.value == Int(event.keyCode) })?.key else { return nil }
        return (parts + [name]).joined(separator: "+")
    }

    /// Display form, e.g. "⌃⌥Space".
    static func pretty(_ spec: String?) -> String {
        guard let spec, !spec.isEmpty else { return "None" }
        let parts = spec.lowercased().split(separator: "+").map(String.init)
        let symbols: [String: String] = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
        let mods = parts.dropLast().map { symbols[$0] ?? $0 }.joined()
        let key = parts.last.map { $0.count == 1 ? $0.uppercased() : $0.capitalized } ?? ""
        return mods + key
    }
}

import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot key API, which needs no Accessibility
/// permission. Carbon delivers the event on the main thread.
///
/// ⌥Space is the default. Avoid ⌘Space (Spotlight or Raycast) and ⌃Space or ⌃⌥Space, which
/// switch input sources.
@MainActor
final class GlobalHotKey {
    struct Shortcut: Equatable, Sendable {
        var keyCode: UInt32
        /// Carbon modifier flags: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
        var modifiers: UInt32
        /// "⌥Space": modifiers in the system order ⌃⌥⇧⌘, then the key.
        var display: String

        init(keyCode: UInt32, modifiers: UInt32, display: String? = nil) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.display = display ?? Self.describe(keyCode: keyCode, modifiers: modifiers)
        }

        static let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        /// The fallback when ⌥Space is taken.
        static let controlOptionCommandSpace = Shortcut(keyCode: UInt32(kVK_Space),
                                                        modifiers: UInt32(controlKey | optionKey | cmdKey))

        /// The same chord as a menu item key equivalent, for display. `nil` for keys other than
        /// Space, which the menu shows without a hint.
        var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
            guard keyCode == UInt32(kVK_Space) else { return nil }
            var flags: NSEvent.ModifierFlags = []
            if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            return (" ", flags)
        }

        /// Reads "option+space", "ctrl+opt+cmd+k", "⌥Space" or "⌃⌥⌘ Space". Needs at least one
        /// modifier unless the key is a function key.
        init?(parsing text: String) {
            var modifiers: UInt32 = 0
            var key: String?
            var remainder = ""
            for character in text {
                if let flag = Self.modifierSymbols[character] {
                    modifiers |= flag
                } else {
                    remainder.append(character)
                }
            }
            let parts = remainder.lowercased()
                .split { $0 == "+" || $0.isWhitespace }
                .map(String.init)
            for part in parts {
                if let flag = Self.modifierNames[part] {
                    modifiers |= flag
                } else if key == nil {
                    key = part
                } else {
                    return nil
                }
            }
            guard let key, let code = Self.keyCodes[key] else { return nil }
            let isFunctionKey = key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()) != nil
            guard modifiers != 0 || isFunctionKey else { return nil }
            self.init(keyCode: code, modifiers: modifiers)
        }

        private static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "\u{2303}" }
            if modifiers & UInt32(optionKey) != 0 { text += "\u{2325}" }
            if modifiers & UInt32(shiftKey) != 0 { text += "\u{21E7}" }
            if modifiers & UInt32(cmdKey) != 0 { text += "\u{2318}" }
            return text + (keyNames[keyCode] ?? "Key \(keyCode)")
        }

        private static let modifierSymbols: [Character: UInt32] = [
            "\u{2303}": UInt32(controlKey), "\u{2325}": UInt32(optionKey),
            "\u{21E7}": UInt32(shiftKey), "\u{2318}": UInt32(cmdKey),
        ]

        private static let modifierNames: [String: UInt32] = [
            "ctrl": UInt32(controlKey), "control": UInt32(controlKey), "ctl": UInt32(controlKey),
            "opt": UInt32(optionKey), "option": UInt32(optionKey), "alt": UInt32(optionKey),
            "shift": UInt32(shiftKey),
            "cmd": UInt32(cmdKey), "command": UInt32(cmdKey),
        ]

        private static let keyCodes: [String: UInt32] = {
            var codes: [String: Int] = [
                "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
                "escape": kVK_Escape, "esc": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete,
                ",": kVK_ANSI_Comma, "comma": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "period": kVK_ANSI_Period,
                "/": kVK_ANSI_Slash, "slash": kVK_ANSI_Slash, ";": kVK_ANSI_Semicolon, "semicolon": kVK_ANSI_Semicolon,
                "'": kVK_ANSI_Quote, "quote": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
                "\\": kVK_ANSI_Backslash, "backslash": kVK_ANSI_Backslash, "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus,
                "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal, "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave,
            ]
            let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                           kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                           kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                           kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
            for (offset, code) in letters.enumerated() {
                codes[String(UnicodeScalar(UInt8(ascii: "a") + UInt8(offset)))] = code
            }
            let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                          kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            for (digit, code) in digits.enumerated() { codes["\(digit)"] = code }
            let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
            for (offset, code) in functions.enumerated() { codes["f\(offset + 1)"] = code }
            return codes.mapValues { UInt32($0) }
        }()

        private static let keyNames: [UInt32: String] = {
            var names: [UInt32: String] = [
                UInt32(kVK_Space): "Space", UInt32(kVK_Return): "\u{21A9}", UInt32(kVK_Tab): "\u{21E5}",
                UInt32(kVK_Escape): "\u{238B}", UInt32(kVK_Delete): "\u{232B}",
            ]
            for (name, code) in keyCodes where names[code] == nil {
                if name.count == 1 || (name.hasPrefix("f") && Int(name.dropFirst()) != nil) {
                    names[code] = name.uppercased()
                }
            }
            return names
        }()
    }

    /// Identifies this app's hot keys in Carbon events: "ClSw".
    nonisolated private static let signature: OSType = 0x436C_5377

    private static var nextIdentifier: UInt32 = 1

    private let handler: @MainActor () -> Void
    private let identifier: UInt32
    // Read in deinit, which is not isolated; only touched on the main thread.
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private(set) var shortcut: Shortcut?

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Replaces any shortcut registered before. `false` when the system or another app holds it.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        guard installHandler() else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: identifier),
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        hotKey = reference
        self.shortcut = shortcut
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        shortcut = nil
    }

    private func installHandler() -> Bool {
        guard eventHandler == nil else { return true }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, owner in
            guard let event, let owner else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                         nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard read == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(owner).takeUnretainedValue()
            let handled = MainActor.assumeIsolated { hotKey.fire(id.id) }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &reference)
        guard status == noErr else { return false }
        eventHandler = reference
        return true
    }

    private func fire(_ id: UInt32) -> Bool {
        guard id == identifier, shortcut != nil else { return false }
        handler()
        return true
    }
}

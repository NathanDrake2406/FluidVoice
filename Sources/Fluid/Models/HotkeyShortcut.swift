import AppKit
import Carbon
import Foundation

struct HotkeyShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: NSEvent.ModifierFlags
    enum CodingKeys: String, CodingKey { case keyCode, modifierFlagsRawValue }

    var displayString: String {
        var parts: [String] = []
        if self.modifierFlags.contains(.function) { parts.append("🌐") }
        if self.modifierFlags.contains(.command) { parts.append("⌘") }
        if self.modifierFlags.contains(.option) { parts.append("⌥") }
        if self.modifierFlags.contains(.control) { parts.append("⌃") }
        if self.modifierFlags.contains(.shift) { parts.append("⇧") }
        parts.append(Self.keyCodeToString(keyCode) ?? "?")

        if self.modifierFlags.isEmpty {
            return parts.last ?? "Unknown"
        }

        return parts.joined(separator: " + ")
    }

    static func keyCodeToString(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 63: return "fn"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default: return characterForKeyCode(keyCode) ?? qwertyFallback[keyCode]
        }
    }

    // US QWERTY names used when TIS layout data is unavailable (e.g. emoji/CJK input sources).
    private static let qwertyFallback: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// Uses the current keyboard layout to resolve a key code to its displayed character.
    static func characterForKeyCode(_ keyCode: UInt16) -> String? {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> String? in
            guard let layoutPtr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layoutPtr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let raw = String(utf16CodeUnits: chars, count: length)
            guard !raw.isEmpty, !raw.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                return nil
            }
            let upper = raw.uppercased()
            return upper.count == raw.count ? upper : raw
        }
    }
}

extension HotkeyShortcut {
    private static let relevantModifierMask: NSEvent.ModifierFlags = [.function, .command, .option, .control, .shift]

    var relevantModifierFlags: NSEvent.ModifierFlags {
        self.modifierFlags.intersection(Self.relevantModifierMask)
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == self.keyCode && modifiers.intersection(Self.relevantModifierMask) == self.relevantModifierFlags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        let raw = try c.decode(UInt.self, forKey: .modifierFlagsRawValue)
        self.modifierFlags = NSEvent.ModifierFlags(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.keyCode, forKey: .keyCode)
        try c.encode(self.modifierFlags.rawValue, forKey: .modifierFlagsRawValue)
    }
}

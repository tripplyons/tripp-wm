/// A key with modifiers, written like `alt-shift-h`.
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Virtual key code for the ANSI layout position.
    public let keyCode: UInt32
    public let modifiers: Modifiers
    public let description: String

    public init(parsing text: String) throws {
        let parts = text.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        // A trailing "-" names the minus key: "alt--".
        var names = parts
        var key = names.removeLast()
        if key.isEmpty, names.last?.isEmpty == true {
            names.removeLast()
            key = "minus"
        }
        var modifiers: Modifiers = []
        for name in names {
            switch name {
            case "alt", "option", "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "ctrl", "control": modifiers.insert(.control)
            case "cmd", "command": modifiers.insert(.command)
            default:
                throw ParseError(description: "unknown modifier \"\(name)\" in \"\(text)\"")
            }
        }
        guard let code = Self.keyCodes[key] else {
            throw ParseError(description: "unknown key \"\(key)\" in \"\(text)\"")
        }
        guard !modifiers.isEmpty else {
            throw ParseError(description: "\"\(text)\" needs a modifier")
        }
        keyCode = code
        self.modifiers = modifiers
        description = text
    }

    /// A combo for lookups, such as a key read from an event tap.
    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        let name = Self.keyCodes.filter { $0.value == keyCode }.keys.min() ?? "key\(keyCode)"
        var parts: [String] = []
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.command) { parts.append("cmd") }
        description = (parts + [name]).joined(separator: "-")
    }

    public static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }

    static let keyCodes: [String: UInt32] = {
        var codes: [String: UInt32] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
            "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
            "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
            "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "equal": 0x18,
            "9": 0x19, "7": 0x1A, "minus": 0x1B, "8": 0x1C, "0": 0x1D,
            "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
            "return": 0x24, "enter": 0x24, "l": 0x25, "j": 0x26, "'": 0x27,
            "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D,
            "m": 0x2E, ".": 0x2F, "tab": 0x30, "space": 0x31, "`": 0x32,
            "delete": 0x33, "escape": 0x35,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        let functionKeys: [UInt32] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
            0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for (index, code) in functionKeys.enumerated() {
            codes["f\(index + 1)"] = code
        }
        return codes
    }()
}

/// A mode toggled by tapping right Option alone. While it is on, every key
/// runs the binding it would run with Option held, and no key reaches apps.
///
/// This type only decides; the app feeds it keyboard events from a tap.
public struct ActionMode: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Let the event continue to the app.
        case pass
        /// Drop the event.
        case swallow
        /// Drop the event and run the command.
        case run(Command)
    }

    public static let rightOptionKeyCode: UInt32 = 0x3D
    static let escapeKeyCode: UInt32 = 0x35
    static let iKeyCode: UInt32 = 0x22

    public private(set) var isOn = false
    public var bindings: [KeyCombo: Command]

    /// Right Option is down and no other key has been pressed since.
    private var rightOptionAlone = false
    /// Keys whose key down was dropped. Their key ups are dropped too, even
    /// after the mode ends.
    private var heldKeys: Set<UInt32> = []

    public init(bindings: [KeyCombo: Command] = [:]) {
        self.bindings = bindings
    }

    /// Whether key events still need to be seen: the mode is on, or a
    /// dropped key has not been released yet.
    public var needsKeys: Bool {
        isOn || !heldKeys.isEmpty
    }

    public mutating func exit() {
        isOn = false
        rightOptionAlone = false
    }

    /// A modifier key went down or up. Modifier events always pass, so apps
    /// keep a correct view of which modifiers are held.
    public mutating func modifierChanged(keyCode: UInt32, rightOptionDown: Bool) -> Outcome {
        guard keyCode == Self.rightOptionKeyCode else {
            rightOptionAlone = false
            return .pass
        }
        if rightOptionDown {
            rightOptionAlone = true
        } else {
            if rightOptionAlone {
                isOn.toggle()
            }
            rightOptionAlone = false
        }
        return .pass
    }

    public mutating func keyDown(keyCode: UInt32, modifiers: KeyCombo.Modifiers, isRepeat: Bool) -> Outcome {
        rightOptionAlone = false
        guard isOn else {
            return .pass
        }
        heldKeys.insert(keyCode)
        if isRepeat {
            return .swallow
        }
        let plain = modifiers.subtracting(.option).isEmpty
        if plain, keyCode == Self.escapeKeyCode || keyCode == Self.iKeyCode {
            exit()
            return .swallow
        }
        guard let command = bindings[KeyCombo(keyCode: keyCode, modifiers: modifiers.union(.option))] else {
            return .swallow
        }
        switch command {
        case .grid, .exec:
            // These hand the keyboard to something else.
            exit()
        default:
            break
        }
        return .run(command)
    }

    public mutating func keyUp(keyCode: UInt32) -> Outcome {
        heldKeys.remove(keyCode) == nil ? .pass : .swallow
    }
}

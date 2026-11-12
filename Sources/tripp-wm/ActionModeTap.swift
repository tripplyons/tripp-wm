import AppKit
import TrippWMCore

/// Feeds keyboard events to `ActionMode`. One tap always watches modifier
/// changes for the right Option toggle; a second tap reads and drops keys
/// only while the mode needs them, so normal typing never waits on tripp-wm.
@MainActor
final class ActionModeTap {
    /// Device-dependent flag bit for the right Option key (NX_DEVICERALTKEYMASK).
    private static let rightOptionFlag: UInt64 = 0x40

    var mode = ActionMode()
    /// Whether the mode may turn on, false while tripp-wm is disabled.
    var isAllowed = true
    var onCommand: ((Command) -> Void)?
    var onModeChange: ((Bool) -> Void)?

    private var modifierTap: CFMachPort?
    private var keyTap: CFMachPort?
    private var sources: [CFRunLoopSource] = []
    private var wasOn = false

    /// Returns false when macOS refuses the taps, usually for lack of the
    /// Input Monitoring permission.
    func start() -> Bool {
        guard modifierTap == nil else {
            return true
        }
        guard let modifiers = makeTap([.flagsChanged]) else {
            return false
        }
        guard let keys = makeTap([.keyDown, .keyUp]) else {
            stop(modifiers)
            return false
        }
        modifierTap = modifiers
        keyTap = keys
        CGEvent.tapEnable(tap: modifiers, enable: true)
        CGEvent.tapEnable(tap: keys, enable: false)
        return true
    }

    func exit() {
        mode.exit()
        sync()
    }

    /// Repairs the taps after macOS turns them off. A long stall on the main
    /// thread, such as rescanning every window when tripp-wm is re-enabled,
    /// makes macOS disable the taps, and the notice of that is not always
    /// delivered. An invalidated tap cannot be turned back on, so it is
    /// created again.
    func ensureRunning() {
        guard let modifierTap, let keyTap else {
            return
        }
        if !CFMachPortIsValid(modifierTap) || !CFMachPortIsValid(keyTap) {
            stop(modifierTap)
            stop(keyTap)
            self.modifierTap = nil
            self.keyTap = nil
            mode.reset()
            sync()
            _ = start()
            return
        }
        if !CGEvent.tapIsEnabled(tap: modifierTap) || CGEvent.tapIsEnabled(tap: keyTap) != mode.needsKeys {
            sync()
        }
    }

    /// Forgets keys whose release may have been missed while the taps were
    /// off, then repairs the taps.
    func reset() {
        mode.reset()
        sync()
        ensureRunning()
    }

    private func stop(_ tap: CFMachPort) {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        sources.removeAll { source in
            guard !CFRunLoopSourceIsValid(source) else {
                return false
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            return true
        }
    }

    private func makeTap(_ types: [CGEventType]) -> CFMachPort? {
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let tap = Unmanaged<ActionModeTap>.fromOpaque(refcon).takeUnretainedValue()
                let keep = MainActor.assumeIsolated { tap.handle(type, event) }
                return keep ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            return nil
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        if let source {
            sources.append(source)
        }
        return tap
    }

    /// Returns whether the event should continue to the app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let outcome: ActionMode.Outcome
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            sync()
            return true
        case .flagsChanged:
            let down = event.flags.rawValue & Self.rightOptionFlag != 0
            outcome = mode.modifierChanged(keyCode: code, rightOptionDown: down)
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            outcome = mode.keyDown(keyCode: code, modifiers: Self.modifiers(event.flags), isRepeat: isRepeat)
        case .keyUp:
            outcome = mode.keyUp(keyCode: code)
        default:
            return true
        }
        if !isAllowed {
            mode.exit()
        }
        sync()
        switch outcome {
        case .pass:
            return true
        case .swallow:
            return false
        case let .run(command):
            onCommand?(command)
            return false
        }
    }

    /// Enables the key tap only while needed and reports mode changes.
    private func sync() {
        if let modifierTap {
            CGEvent.tapEnable(tap: modifierTap, enable: true)
        }
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: mode.needsKeys)
        }
        if mode.isOn != wasOn {
            wasOn = mode.isOn
            onModeChange?(mode.isOn)
        }
    }

    private static func modifiers(_ flags: CGEventFlags) -> KeyCombo.Modifiers {
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        return modifiers
    }
}

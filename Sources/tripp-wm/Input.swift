import AppKit
import Carbon.HIToolbox
import TrippWMCore

/// Global key bindings through Carbon hot keys, which consume their keys
/// without Input Monitoring permission.
@MainActor
final class HotKeys {
    private static let signature: OSType = 0x5472_574D // "TrWM"

    private var refs: [EventHotKeyRef] = []
    private var commands: [UInt32: Command] = [:]
    private var handler: EventHandlerRef?
    var onCommand: ((Command) -> Void)?

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, refcon in
                var hotKey = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKey
                )
                guard let refcon else {
                    return OSStatus(eventNotHandledErr)
                }
                let keys = Unmanaged<HotKeys>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { keys.fire(hotKey.id) }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    /// Replaces every binding and returns the keys that another app owns.
    func register(_ bindings: [KeyCombo: Command]) -> [KeyCombo] {
        for ref in refs {
            UnregisterEventHotKey(ref)
        }
        refs = []
        commands = [:]
        var failed: [KeyCombo] = []
        let sorted = bindings.sorted { $0.key.description < $1.key.description }
        for (index, (combo, command)) in sorted.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                Self.carbonModifiers(combo.modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                commands[id] = command
            } else {
                failed.append(combo)
            }
        }
        return failed
    }

    private func fire(_ id: UInt32) {
        if let command = commands[id] {
            onCommand?(command)
        }
    }

    private static func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        return UInt32(flags)
    }
}

/// Observes mouse releases to adopt manual window resizing.
@MainActor
final class EventTap {
    var onMouseUp: (() -> Void)?

    private var tap: CFMachPort?

    /// Returns false when macOS refuses the tap, usually for lack of permission.
    func start() -> Bool {
        let mask = CGEventMask(1) << CGEventType.leftMouseUp.rawValue
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { tap.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type.rawValue {
        case CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue:
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case CGEventType.leftMouseUp.rawValue:
            onMouseUp?()
        default:
            break
        }
    }
}

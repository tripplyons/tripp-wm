import AppKit
import TrippWMCore

/// Shows the pointer grid on the monitor under the pointer and reads its
/// keys through an active event tap, so that no key reaches the app below.
@MainActor
final class PointerGrid {
    struct Colors {
        var background: RGBA
        var text: RGBA
        var accent: RGBA
    }

    var colors = Colors(background: Config().gridBackground, text: Config().gridText, accent: Config().gridAccent)
    /// Keys bound to the grid command, which close the grid while it is open.
    var toggleKeys: Set<KeyCombo> = []

    private var grid: Grid?
    private var tap: CFMachPort?
    /// Keys pressed while the grid was open. Their releases are dropped too,
    /// even after the grid closes.
    private var heldKeys: Set<Int64> = []

    private lazy var view = GridView()
    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        // Cover the menu bar and the Dock.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        return window
    }()

    func toggle() {
        if grid == nil {
            open()
        } else {
            close()
        }
    }

    func dismiss() {
        close()
    }

    private func open() {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let monitors = Screens.monitors()
        guard let monitor = monitors.first(where: { $0.frame.contains(pointer) }) ?? monitors.first,
              startTap()
        else { return }
        grid = Grid(area: monitor.frame)
        window.setFrame(Screens.flip(monitor.frame), display: false)
        redraw()
        window.orderFrontRegardless()
    }

    private func close() {
        grid = nil
        window.orderOut(nil)
        stopTapWhenReleased()
    }

    private func redraw() {
        guard let grid else {
            return
        }
        view.grid = grid
        view.colors = colors
        view.needsDisplay = true
    }

    // MARK: Keys

    private func startTap() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }
        let types = [CGEventType.keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << CGEventMask($1.rawValue) }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }
                let grid = Unmanaged<PointerGrid>.fromOpaque(refcon).takeUnretainedValue()
                let keep = MainActor.assumeIsolated { grid.handle(type, event) }
                return keep ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else {
            FileHandle.standardError.write(Data("tripp-wm: cannot read keys for the pointer grid\n".utf8))
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopTapWhenReleased() {
        if heldKeys.isEmpty, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// Returns whether the event should continue to the app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if grid != nil, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return true
        case .keyUp:
            guard heldKeys.remove(code) != nil else {
                return true
            }
            if grid == nil {
                stopTapWhenReleased()
            }
            return false
        case .keyDown:
            guard grid != nil else {
                return true
            }
            heldKeys.insert(code)
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                press(UInt32(code), modifiers: Self.modifiers(event.flags))
            }
            return false
        default:
            return true
        }
    }

    private func press(_ code: UInt32, modifiers: KeyCombo.Modifiers) {
        if toggleKeys.contains(where: { $0.keyCode == code && $0.modifiers == modifiers }) {
            close()
            return
        }
        guard var grid else {
            return
        }
        let outcome = grid.handle(Grid.Key(keyCode: code, modifiers: modifiers))
        self.grid = grid
        switch outcome {
        case .pending:
            redraw()
        case .cancel:
            close()
        case let .click(point, button):
            close()
            Self.click(at: point, with: button)
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

    // MARK: Clicks

    /// Moves the pointer and clicks without the modifiers that chose the button.
    private static func click(at point: CGPoint, with button: Grid.Button) {
        let source = CGEventSource(stateID: .privateState)
        let (down, up, mouseButton): (CGEventType, CGEventType, CGMouseButton) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .left)
        case .right: (.rightMouseDown, .rightMouseUp, .right)
        case .middle: (.otherMouseDown, .otherMouseUp, .center)
        }
        for type in [CGEventType.mouseMoved, down, up] {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: mouseButton
            ) else { continue }
            event.flags = []
            if type != .mouseMoved {
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Draws cells with full-strength labels only for the matching prefix.
private final class GridView: NSView {
    var grid: Grid?
    var colors: PointerGrid.Colors?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let grid, let colors else {
            return
        }
        let background = Self.color(colors.background)
        let text = Self.color(colors.text)
        let accent = Self.color(colors.accent)
        background.setFill()
        bounds.fill()

        // The view's origin is the grid area's top-left corner.
        let origin = grid.area.origin
        func local(_ rect: CGRect) -> CGRect {
            rect.offsetBy(dx: -origin.x, dy: -origin.y)
        }

        let lines = NSBezierPath()
        lines.lineWidth = 0.5
        for index in 1..<grid.columns {
            let x = local(grid.cell(row: 0, column: index)).minX
            lines.move(to: CGPoint(x: x, y: bounds.minY))
            lines.line(to: CGPoint(x: x, y: bounds.maxY))
        }
        for index in 1..<grid.rows {
            let y = local(grid.cell(row: index, column: 0)).minY
            lines.move(to: CGPoint(x: bounds.minX, y: y))
            lines.line(to: CGPoint(x: bounds.maxX, y: y))
        }
        text.withAlphaComponent(0.15).setStroke()
        lines.stroke()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let dimmed = !grid.matches(row: row, column: column)
                let first = dimmed ? text.withAlphaComponent(0.25) : accent
                let second = dimmed ? text.withAlphaComponent(0.25) : text
                let label = grid.label(row: row, column: column)
                let string = NSMutableAttributedString(
                    string: label,
                    attributes: [.font: font, .foregroundColor: second]
                )
                string.addAttribute(.foregroundColor, value: first, range: NSRange(location: 0, length: 1))
                let size = string.size()
                let cell = local(grid.cell(row: row, column: column))
                string.draw(at: CGPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
            }
        }
    }

    private static func color(_ rgba: RGBA) -> NSColor {
        NSColor(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

import AppKit
import TrippWMCore

/// A click-through outline around the focused window, ordered just above it
/// so that windows in front of the focused one still cover it.
@MainActor
final class Border {
    private static let cornerRadius = 12.0
    private let clock = AnimationClock()
    private var motion = BorderAnimation()
    private var clockRunning = false
    private var monitor: MonitorID?
    private var width = 0.0
    private var relativeWindow: WindowID?

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
        return window
    }()

    /// Shows the outline around a frame in Accessibility coordinates.
    func show(
        around frame: CGRect, above id: WindowID, width: Double, color: RGBA,
        animation: AnimationSettings, monitor: MonitorID?
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        self.width = width
        let current = motion.update(frame: frame, window: id, at: now, settings: animation)
        draw(current)
        if let layer = window.contentView?.layer {
            layer.borderWidth = width
            layer.cornerRadius = Self.cornerRadius + width
            layer.borderColor = CGColor(
                srgbRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
        }
        // The manager is normally inactive. Relative ordering alone does not
        // bring an inactive app's window on screen.
        if relativeWindow != id || !window.isVisible {
            window.orderFrontRegardless()
            window.order(.above, relativeTo: Int(id))
            relativeWindow = id
        }
        if motion.isAnimating(at: now) {
            if !clockRunning || self.monitor != monitor {
                clock.start(on: monitor) { [weak self] in self?.advance() }
                clockRunning = true
            }
        } else {
            stopClock()
        }
        self.monitor = monitor
    }

    private func draw(_ frame: CGRect) {
        let outer = frame.insetBy(dx: -width, dy: -width)
        window.setFrame(Screens.flip(outer), display: false)
    }

    private func advance() {
        let now = ProcessInfo.processInfo.systemUptime
        if let frame = motion.frame(at: now) { draw(frame) }
        if !motion.isAnimating(at: now) { stopClock() }
    }

    private func stopClock() {
        clock.stop()
        clockRunning = false
    }

    func hide() {
        stopClock()
        motion.hide()
        relativeWindow = nil
        window.orderOut(nil)
    }
}

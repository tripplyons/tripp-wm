import Foundation

/// Focus changes glide from the current outline. Geometry updates for the
/// same window follow it directly, or update a glide without restarting it.
public struct BorderAnimation: Sendable {
    private var window: WindowID?
    private var target: CGRect?
    private var transition: FrameAnimation?

    public init() {}

    @discardableResult
    public mutating func update(
        frame: CGRect, window id: WindowID, at time: TimeInterval,
        settings: AnimationSettings
    ) -> CGRect {
        let current = self.frame(at: time)
        if settings.duration <= 0 {
            transition = nil
        } else if window != id {
            if let current, current != frame {
                transition = FrameAnimation(from: current, to: frame, start: time, settings: settings)
            } else {
                transition = nil
            }
        } else if let pending = transition, !pending.isFinished(at: time) {
            transition = FrameAnimation(from: pending.from, to: frame, start: pending.start, settings: pending.settings)
        } else {
            transition = nil
        }
        window = id
        target = frame
        return self.frame(at: time) ?? frame
    }

    public func frame(at time: TimeInterval) -> CGRect? {
        transition?.frame(at: time) ?? target
    }

    public func isAnimating(at time: TimeInterval) -> Bool {
        transition.map { !$0.isFinished(at: time) } ?? false
    }

    public mutating func hide() {
        window = nil
        target = nil
        transition = nil
    }
}

import Foundation

public enum AnimationEasing: String, Codable, Sendable {
    case linear
    case easeOutCubic = "ease-out-cubic"
    case easeInOutCubic = "ease-in-out-cubic"

    public func value(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        switch self {
        case .linear: return t
        case .easeOutCubic: return 1 - pow(1 - t, 3)
        case .easeInOutCubic:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

public struct AnimationSettings: Equatable, Sendable {
    /// Milliseconds. Zero disables animation.
    public var duration = 180.0
    public var easing = AnimationEasing.easeOutCubic

    public init() {}
}

/// A frame transition evaluated with a monotonic clock, independent of timers
/// and Accessibility. Retarget by starting a new transition at the current frame.
public struct FrameAnimation: Sendable {
    public let from: CGRect
    public let to: CGRect
    public let start: TimeInterval
    public let settings: AnimationSettings

    public init(from: CGRect, to: CGRect, start: TimeInterval, settings: AnimationSettings) {
        self.from = from
        self.to = to
        self.start = start
        self.settings = settings
    }

    public func isFinished(at time: TimeInterval) -> Bool {
        settings.duration <= 0 || time - start >= settings.duration / 1000
    }

    public func frame(at time: TimeInterval) -> CGRect {
        if isFinished(at: time) { return to }
        let t = settings.easing.value(at: (time - start) / (settings.duration / 1000))
        return CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }
}

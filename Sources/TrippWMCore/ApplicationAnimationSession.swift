/// The app-level Accessibility setting that can add native resize animations.
public protocol ApplicationAnimationBackend {
    var enhancedUserInterface: Bool { get }
    @discardableResult func setEnhancedUserInterface(_ enabled: Bool) -> Bool
}

/// Suppresses native resize animations once for a whole transition, rather than
/// toggling Accessibility mode on every frame. The owner must call finish on
/// completion or cancellation. Sessions can be retained across retargets.
public final class ApplicationAnimationSession {
    private let backend: any ApplicationAnimationBackend
    private var needsRestore: Bool

    public init(backend: any ApplicationAnimationBackend) {
        self.backend = backend
        needsRestore = backend.enhancedUserInterface && backend.setEnhancedUserInterface(false)
    }

    public func finish() {
        guard needsRestore else { return }
        backend.setEnhancedUserInterface(true)
        needsRestore = false
    }
}

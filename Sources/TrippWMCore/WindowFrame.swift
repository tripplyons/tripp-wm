import Foundation

/// The Accessibility boundary used to apply frames. Tests supply an in-memory
/// backend; the window manager supplies an AXUIElement.
public protocol WindowFrameBackend {
    var frame: CGRect? { get }
    @discardableResult func setPosition(_ point: CGPoint) -> Bool
    @discardableResult func setSize(_ size: CGSize) -> Bool
}

/// Applies only changed attributes and returns the last successfully requested
/// frame. The caller can reuse it during animation, then reconcile with the real
/// frame at completion or interruption because apps can constrain valid requests.
public func applyWindowFrame(
    _ target: CGRect, to backend: any WindowFrameBackend, current cached: CGRect? = nil
) -> CGRect? {
    guard let current = cached ?? backend.frame else { return nil }
    let resize = abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1
    let move = abs(current.minX - target.minX) > 1 || abs(current.minY - target.minY) > 1
    guard resize || move else { return current }

    // Size first so the move fits, then retry after moving in case the old
    // position constrained the size. Pure moves never write the size.
    if resize { backend.setSize(target.size) }
    let moved = backend.setPosition(target.origin)
    let resized = resize ? backend.setSize(target.size) : true
    guard moved, resized else { return nil }
    return CGRect(origin: target.origin, size: resize ? target.size : current.size)
}

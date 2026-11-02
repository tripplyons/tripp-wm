import Foundation

/// Runs one operation at a time and retains only the newest pending value.
/// A slow consumer skips obsolete frames instead of building a queue of them.
public final class LatestValueWorker<Value: Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tripp-wm.frame-writer", qos: .userInteractive)
    private let lock = NSLock()
    private let operation: @Sendable (Value) -> Void
    private var pending: Value?
    private var running = false

    public init(operation: @escaping @Sendable (Value) -> Void) {
        self.operation = operation
    }

    public func submit(_ value: Value) {
        lock.lock()
        pending = value
        let start = !running
        running = true
        lock.unlock()
        if start {
            queue.async { self.drain() }
        }
    }

    /// Discards pending work. An operation already in progress can finish.
    public func cancel() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    /// Waits for outstanding writes before a layout reads or changes real frames.
    public func wait() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            operation(value)
        }
    }
}

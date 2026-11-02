import Foundation
import Testing
import TrippWMCore

private final class FakeWindow: WindowFrameBackend {
    enum Write: Equatable {
        case position(CGPoint)
        case size(CGSize)
    }

    var actual = CGRect(x: 10, y: 20, width: 400, height: 300)
    var reads = 0
    var writes: [Write] = []
    var acceptsPosition = true
    var acceptsSize = true
    var maximumX: CGFloat?

    var frame: CGRect? {
        reads += 1
        return actual
    }

    func setPosition(_ point: CGPoint) -> Bool {
        writes.append(.position(point))
        guard acceptsPosition else { return false }
        actual.origin = point
        if let maximumX { actual.origin.x = min(actual.origin.x, maximumX) }
        return true
    }

    func setSize(_ size: CGSize) -> Bool {
        writes.append(.size(size))
        guard acceptsSize else { return false }
        actual.size = size
        return true
    }
}

struct WindowFrameTests {
    @Test func pureMovesDoNotResizeOrReadCachedFrames() {
        let window = FakeWindow()
        var cached: CGRect? = window.actual
        for x in stride(from: 20, through: 100, by: 10) {
            let target = CGRect(x: x, y: 20, width: 400, height: 300)
            cached = applyWindowFrame(target, to: window, current: cached)
            #expect(cached == target)
            #expect(window.actual == target)
        }
        #expect(window.reads == 0)
        #expect(window.writes.count == 9)
        #expect(window.writes.allSatisfy {
            if case .position = $0 { return true }
            return false
        })
    }

    @Test func resizingKeepsSizeMoveSizeOrder() {
        let window = FakeWindow()
        let target = CGRect(x: 50, y: 60, width: 500, height: 350)
        #expect(applyWindowFrame(target, to: window) == target)
        #expect(window.reads == 1)
        #expect(window.writes == [.size(target.size), .position(target.origin), .size(target.size)])
    }

    @Test func unchangedFramesDoNotWrite() {
        let window = FakeWindow()
        #expect(applyWindowFrame(window.actual, to: window, current: window.actual) == window.actual)
        #expect(window.reads == 0)
        #expect(window.writes.isEmpty)
        var target = window.actual
        target.origin.x += 0.5
        target.size.width += 0.5
        #expect(applyWindowFrame(target, to: window, current: window.actual) == window.actual)
        #expect(window.writes.isEmpty)
    }

    @Test func failedWritesInvalidateCacheAndNextUpdateReadsActualFrame() {
        let window = FakeWindow()
        let target = CGRect(x: 200, y: 20, width: 400, height: 300)
        window.acceptsPosition = false
        let cached = applyWindowFrame(target, to: window, current: window.actual)
        #expect(cached == nil)
        window.acceptsPosition = true
        #expect(applyWindowFrame(target, to: window, current: cached) == target)
        #expect(window.reads == 1)

        window.acceptsSize = false
        var resized = target
        resized.size.width = 600
        #expect(applyWindowFrame(resized, to: window, current: target) == nil)
    }

    @Test func actualFramesReconcileAppConstraintsAtAnimationBoundaries() {
        let window = FakeWindow()
        window.maximumX = 100
        let target = CGRect(x: 200, y: 20, width: 400, height: 300)
        #expect(applyWindowFrame(target, to: window, current: window.actual) == target)
        #expect(window.actual.minX == 100)
        // A successful request is not proof the app accepted the full geometry.
        // At interruption, a fresh read supplies the next animation's start.
        let next = FrameAnimation(from: window.frame!, to: .zero, start: 10, settings: AnimationSettings())
        #expect(next.frame(at: 10).minX == 100)
        // Completion bypasses the cache and retries a constrained destination.
        _ = applyWindowFrame(target, to: window)
        #expect(window.reads == 2)
        #expect(window.writes.count == 2)
    }
}

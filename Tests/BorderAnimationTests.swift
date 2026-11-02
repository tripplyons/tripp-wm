import Foundation
import Testing
import TrippWMCore

struct BorderAnimationTests {
    private let first = CGRect(x: 10, y: 20, width: 200, height: 300)
    private let second = CGRect(x: 410, y: 60, width: 400, height: 500)

    private var settings: AnimationSettings {
        var settings = AnimationSettings()
        settings.duration = 1000
        settings.easing = .linear
        return settings
    }

    @Test func firstShowSnapsAndFocusChangeGlidesPositionAndSize() {
        var border = BorderAnimation()
        #expect(border.update(frame: first, window: 1, at: 0, settings: settings) == first)
        #expect(!border.isAnimating(at: 0))
        #expect(border.update(frame: second, window: 2, at: 1, settings: settings) == first)
        #expect(border.isAnimating(at: 1))
        #expect(border.frame(at: 1.5) == CGRect(x: 210, y: 40, width: 300, height: 400))
        #expect(border.frame(at: 2) == second)
        #expect(!border.isAnimating(at: 2))
    }

    @Test func rapidFocusChangesRetargetFromDisplayedFrame() {
        var border = BorderAnimation()
        border.update(frame: first, window: 1, at: 0, settings: settings)
        border.update(frame: second, window: 2, at: 1, settings: settings)
        let current = border.frame(at: 1.25)
        #expect(border.update(frame: first, window: 1, at: 1.25, settings: settings) == current)
        #expect(border.frame(at: 2.25) == first)
        #expect(!border.isAnimating(at: 2.25))
    }

    @Test func movingFocusedWindowFollowsWithoutLag() {
        var border = BorderAnimation()
        border.update(frame: first, window: 1, at: 0, settings: settings)
        #expect(border.update(frame: second, window: 1, at: 0.1, settings: settings) == second)
        #expect(!border.isAnimating(at: 0.1))
    }

    @Test func movingDestinationDoesNotRestartGlide() {
        var border = BorderAnimation()
        border.update(frame: first, window: 1, at: 0, settings: settings)
        border.update(frame: second, window: 2, at: 1, settings: settings)
        let moved = second.offsetBy(dx: 100, dy: 200)
        border.update(frame: moved, window: 2, at: 1.5, settings: settings)
        #expect(border.frame(at: 1.5) == CGRect(x: 260, y: 140, width: 300, height: 400))
        #expect(border.frame(at: 2) == moved)
        #expect(!border.isAnimating(at: 2))
        let final = moved.offsetBy(dx: 10, dy: 20)
        #expect(border.update(frame: final, window: 2, at: 2.1, settings: settings) == final)
    }

    @Test func zeroDurationCancelsGlideAndNewFocusSnaps() {
        var border = BorderAnimation()
        border.update(frame: first, window: 1, at: 0, settings: settings)
        border.update(frame: second, window: 2, at: 1, settings: settings)
        var disabled = settings
        disabled.duration = 0
        #expect(border.update(frame: second, window: 2, at: 1.1, settings: disabled) == second)
        #expect(!border.isAnimating(at: 1.1))
        #expect(border.update(frame: first, window: 1, at: 1.2, settings: disabled) == first)
        #expect(!border.isAnimating(at: 1.2))
    }

    @Test func hideClearsGlideAndNextShowSnaps() {
        var border = BorderAnimation()
        border.update(frame: first, window: 1, at: 0, settings: settings)
        border.update(frame: second, window: 2, at: 1, settings: settings)
        border.hide()
        #expect(border.frame(at: 1.5) == nil)
        #expect(!border.isAnimating(at: 1.5))
        #expect(border.update(frame: second, window: 2, at: 2, settings: settings) == second)
        #expect(!border.isAnimating(at: 2))
    }

    @Test func identicalFramesNeedNoGlide() {
        var border = BorderAnimation()
        border.update(frame: first, window: 1, at: 0, settings: settings)
        #expect(border.update(frame: first, window: 2, at: 1, settings: settings) == first)
        #expect(!border.isAnimating(at: 1))
    }
}

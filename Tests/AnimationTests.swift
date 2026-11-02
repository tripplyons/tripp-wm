import Foundation
import Testing
import TrippWMCore

struct AnimationTests {
    @Test func configuration() throws {
        let defaults = try Config(parsing: "")
        #expect(defaults.focusAnimation.duration == 180)
        #expect(defaults.moveAnimation.easing == .easeOutCubic)
        let config = try Config(parsing: """
        [animations.focus]
        duration = 0
        [animations.move]
        duration = 250
        easing = "ease-in-out-cubic"
        """)
        #expect(config.focusAnimation.duration == 0)
        #expect(config.moveAnimation.duration == 250)
        #expect(config.moveAnimation.easing == .easeInOutCubic)
        for value in ["-1", "nan", "inf"] {
            #expect(throws: Config.LoadError.self) {
                try Config(parsing: "[animations.focus]\nduration = \(value)")
            }
        }
        #expect(throws: Config.LoadError.self) {
            try Config(parsing: "[animations.move]\neasing = 'unknown'")
        }
    }

    @Test func curvesClampAndEase() {
        for easing in [AnimationEasing.linear, .easeOutCubic, .easeInOutCubic] {
            #expect(easing.value(at: -1) == 0)
            #expect(easing.value(at: 2) == 1)
        }
        #expect(AnimationEasing.linear.value(at: 0.5) == 0.5)
        #expect(AnimationEasing.easeOutCubic.value(at: 0.5) == 0.875)
        #expect(AnimationEasing.easeInOutCubic.value(at: 0.5) == 0.5)
    }

    @Test func framesAndRetargeting() {
        var settings = AnimationSettings()
        settings.duration = 1000
        settings.easing = .linear
        let from = CGRect(x: 0, y: 20, width: 100, height: 200)
        let to = CGRect(x: 200, y: 40, width: 300, height: 400)
        let animation = FrameAnimation(from: from, to: to, start: 10, settings: settings)
        #expect(animation.frame(at: 9) == from)
        #expect(animation.frame(at: 10.5) == CGRect(x: 100, y: 30, width: 200, height: 300))
        #expect(!animation.isFinished(at: 10.5))
        #expect(animation.frame(at: 11) == to)
        #expect(animation.isFinished(at: 11))
        let current = animation.frame(at: 10.5)
        let retargeted = FrameAnimation(from: current, to: from, start: 10.5, settings: settings)
        #expect(retargeted.frame(at: 10.5) == current)
        #expect(retargeted.frame(at: 11.5) == from)
        settings.duration = 0
        #expect(FrameAnimation(from: from, to: to, start: 0, settings: settings).frame(at: 0) == to)
    }
}

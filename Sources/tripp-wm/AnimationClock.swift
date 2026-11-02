import AppKit
import QuartzCore
import TrippWMCore

/// Owns the display link's Objective-C target separately from the manager, so
/// the link cannot retain the manager through its callback.
@MainActor
final class AnimationClock: NSObject {
    private var link: CADisplayLink?
    private var callback: (() -> Void)?

    func start(on monitor: MonitorID?, callback: @escaping () -> Void) {
        stop()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == monitor
        }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        self.callback = callback
        let link = screen.displayLink(target: self, selector: #selector(tick))
        let maximum = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        callback = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        callback?()
    }
}

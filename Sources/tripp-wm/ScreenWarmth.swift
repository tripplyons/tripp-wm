import AppKit
import CoreGraphics
import TrippWMCore

private struct CoreGraphicsGammaBackend: DisplayGammaBackend {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func connectedDisplays() throws -> [UInt32] {
        var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(0, nil, &count), operation: "Cannot list displays")
        guard count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetOnlineDisplayList(count, &displays, &count), operation: "Cannot list displays")
        return Array(displays.prefix(Int(count)))
    }

    func readGamma(for display: UInt32) throws -> DisplayGammaTable {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else {
            throw Failure(description: "Display color adjustment is not supported")
        }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        try check(
            CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &count),
            operation: "Cannot read display color curves"
        )
        return DisplayGammaTable(
            red: Array(red.prefix(Int(count))),
            green: Array(green.prefix(Int(count))),
            blue: Array(blue.prefix(Int(count)))
        )
    }

    func writeGamma(_ table: DisplayGammaTable, for display: UInt32) throws {
        try check(
            CGSetDisplayTransferByTable(display, UInt32(table.red.count), table.red, table.green, table.blue),
            operation: "Cannot set display color curves"
        )
    }

    private func check(_ result: CGError, operation: String) throws {
        guard result == .success else {
            throw Failure(description: "\(operation) (CoreGraphics error \(result.rawValue))")
        }
    }
}

/// Manual screen warmth is independent of Accessibility and window tiling.
@MainActor
final class ScreenWarmth {
    private static let preferenceKey = "screenWarmth"
    private let defaults: UserDefaults
    private let controller = ScreenWarmthController(backend: CoreGraphicsGammaBackend())
    private let controls = ScreenWarmthMenuView()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var reapplyTimer: Timer?
    private var lastIssues: [ScreenWarmthIssue] = []
    private var isRunning = false

    let menuItem = NSMenuItem()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuItem.view = controls
        controls.onChange = { [weak self] amount in self?.setAmount(amount) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let amount = ScreenWarmthController.clamp(defaults.double(forKey: Self.preferenceKey))
        report(controller.setAmount(amount))

        observe(NSApplication.didChangeScreenParametersNotification, in: .default)
        observe(NSWorkspace.didWakeNotification, in: NSWorkspace.shared.notificationCenter)
        observe(NSWorkspace.screensDidWakeNotification, in: NSWorkspace.shared.notificationCenter)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        reapplyTimer?.invalidate()
        reapplyTimer = nil
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        // Leave the preference intact for the next launch.
        report(controller.restore())
    }

    private func setAmount(_ amount: Double) {
        guard isRunning else { return }
        let amount = ScreenWarmthController.clamp(amount)
        defaults.set(amount, forKey: Self.preferenceKey)
        report(controller.setAmount(amount))
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReapply() }
        }
        observers.append((center, observer))
    }

    private func scheduleReapply() {
        guard isRunning else { return }
        // Display/wake notifications arrive in bursts. Give ColorSync time to
        // finish before reapplying, including while the menu is tracking.
        reapplyTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.report(self.controller.reapply())
            }
        }
        reapplyTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func report(_ issues: [ScreenWarmthIssue]) {
        controls.update(amount: controller.amount, issues: issues)
        if issues != lastIssues {
            for issue in issues {
                FileHandle.standardError.write(Data("tripp-wm: screen warmth: \(issue)\n".utf8))
            }
        }
        lastIssues = issues
    }
}

@MainActor
private final class ScreenWarmthMenuView: NSView {
    var onChange: ((Double) -> Void)?
    private let valueLabel = NSTextField(labelWithString: "Off")
    private let detailLabel = NSTextField(wrappingLabelWithString: "All displays. Independent of tiling.")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 118))
        let title = NSTextField(labelWithString: "Screen warmth")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 20, y: 88, width: 170, height: 20)
        addSubview(title)

        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.frame = NSRect(x: 190, y: 88, width: 70, height: 18)
        addSubview(valueLabel)

        slider.frame = NSRect(x: 20, y: 56, width: 240, height: 24)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel("Screen warmth")
        slider.toolTip = "Adjust all displays from Off to Warm. Turn off Night Shift and other color tools to avoid conflicts."
        addSubview(slider)

        let off = NSTextField(labelWithString: "Off")
        off.frame = NSRect(x: 20, y: 39, width: 100, height: 16)
        let warm = NSTextField(labelWithString: "Warm")
        warm.alignment = .right
        warm.frame = NSRect(x: 160, y: 39, width: 100, height: 16)
        for label in [off, warm] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 20, y: 4, width: 240, height: 32)
        addSubview(detailLabel)
    }

    required init?(coder: NSCoder) { nil }

    func update(amount: Double, issues: [ScreenWarmthIssue]) {
        slider.doubleValue = amount * 100
        let percent = Int((amount * 100).rounded())
        valueLabel.stringValue = amount == 0 ? "Off" : "\(percent)%"
        slider.setAccessibilityValueDescription(valueLabel.stringValue)
        detailLabel.stringValue = issues.isEmpty
            ? "All displays. Independent of tiling."
            : "Display color adjustment failed. See log."
        detailLabel.textColor = issues.isEmpty ? .secondaryLabelColor : .systemOrange
        detailLabel.toolTip = issues.isEmpty ? nil : issues.map(\.description).joined(separator: "\n")
        detailLabel.setAccessibilityHelp(detailLabel.toolTip)
    }

    @objc private func changed() {
        // Whole percentages make the Off endpoint and the saved value exact.
        onChange?(slider.doubleValue.rounded() / 100)
    }
}

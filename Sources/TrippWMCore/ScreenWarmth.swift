import Foundation

/// A display's calibrated RGB transfer curves. Warmth always starts from these
/// curves, never from an already warmed result.
public struct DisplayGammaTable: Equatable, Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var isValid: Bool {
        !red.isEmpty && red.count == green.count && red.count == blue.count
            && [red, green, blue].allSatisfy { channel in
                channel.allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
    }

    /// A manual strength, not a calibrated color temperature. At maximum,
    /// retain red while reducing green by 30% and blue by 60%.
    public func warmed(by amount: Double) -> DisplayGammaTable {
        let strength = Float(ScreenWarmthController.clamp(amount))
        return DisplayGammaTable(
            red: red,
            green: green.map { $0 * (1 - 0.30 * strength) },
            blue: blue.map { $0 * (1 - 0.60 * strength) }
        )
    }
}

/// The CoreGraphics adapter lives in the app. Tests use in-memory displays.
public protocol DisplayGammaBackend {
    func connectedDisplays() throws -> [UInt32]
    func readGamma(for display: UInt32) throws -> DisplayGammaTable
    func writeGamma(_ table: DisplayGammaTable, for display: UInt32) throws
}

public struct ScreenWarmthIssue: Equatable, Sendable, CustomStringConvertible {
    public let display: UInt32?
    public let message: String

    public var description: String {
        if let display {
            return "Display \(display): \(message)"
        }
        return message
    }
}

/// Call from one thread. Keeps each display's original curves until restored or
/// disconnected. A failing display does not stop the others from updating.
public final class ScreenWarmthController {
    public private(set) var amount: Double = 0
    private let backend: any DisplayGammaBackend
    private var originals: [UInt32: DisplayGammaTable] = [:]

    public init(backend: any DisplayGammaBackend) {
        self.backend = backend
    }

    public static func clamp(_ amount: Double) -> Double {
        amount.isFinite ? min(1, max(0, amount)) : 0
    }

    @discardableResult
    public func setAmount(_ amount: Double) -> [ScreenWarmthIssue] {
        self.amount = Self.clamp(amount)
        return reapply()
    }

    /// Reapply after wake or a display change, without compounding the tint.
    @discardableResult
    public func reapply() -> [ScreenWarmthIssue] {
        // Off must not even read gamma tables on displays we have not touched.
        guard amount > 0 || !originals.isEmpty else { return [] }
        let displays: [UInt32]
        do {
            displays = try backend.connectedDisplays()
        } catch {
            return [ScreenWarmthIssue(display: nil, message: "Cannot list displays: \(error)")]
        }
        let connected = Set(displays)
        originals = originals.filter { connected.contains($0.key) }
        var issues: [ScreenWarmthIssue] = []
        for display in connected.sorted() {
            do {
                if amount == 0 {
                    guard let original = originals[display] else { continue }
                    try backend.writeGamma(original, for: display)
                    originals.removeValue(forKey: display)
                } else {
                    if originals[display] == nil {
                        let original = try backend.readGamma(for: display)
                        guard original.isValid else {
                            issues.append(ScreenWarmthIssue(display: display, message: "Invalid display color curves"))
                            continue
                        }
                        originals[display] = original
                    }
                    if let original = originals[display] {
                        try backend.writeGamma(original.warmed(by: amount), for: display)
                    }
                }
            } catch {
                // Keep the original on write failure so Off/quit can retry.
                issues.append(ScreenWarmthIssue(display: display, message: "\(error)"))
            }
        }
        return issues
    }

    /// Does not change the saved preference; the app owns persistence.
    @discardableResult
    public func restore() -> [ScreenWarmthIssue] {
        setAmount(0)
    }
}

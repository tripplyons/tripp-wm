import CoreGraphics

/// A keyboard-driven pointer grid with three-letter labels in row order.
/// The final letter clicks the cell's center with the chosen modifiers.
public struct Grid: Sendable {
    public static let letters = Array("abcdefghijklmnopqrstuvwxyz")
    public static let capacity = 26 * 26 * 26

    public enum Button: Equatable, Sendable {
        case left, right, middle
    }

    public enum Key: Equatable, Sendable {
        case letter(Character, KeyCombo.Modifiers)
        case backspace
        case escape
        case other

        /// Reads a key press by its ANSI position, so labels match the
        /// printed keys on a QWERTY keyboard.
        public init(keyCode: UInt32, modifiers: KeyCombo.Modifiers) {
            switch keyCode {
            case KeyCombo.keyCodes["delete"]: self = .backspace
            case KeyCombo.keyCodes["escape"]: self = .escape
            default:
                let letter = Grid.letters.first { KeyCombo.keyCodes[String($0)] == keyCode }
                self = letter.map { .letter($0, modifiers) } ?? .other
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case pending
        case cancel
        case click(CGPoint, Button)
    }

    /// The covered area in Accessibility coordinates.
    public let area: CGRect
    public let rows: Int
    public let columns: Int
    public private(set) var prefix = ""

    public init(area: CGRect) {
        self.area = area
        var columns = max(1, Int((area.width / 24).rounded()))
        var rows = max(1, Int((area.height / 24).rounded()))
        // Keep labels unique even on exceptionally large displays.
        while Double(columns) * Double(rows) > Double(Self.capacity) {
            if columns >= rows { columns -= 1 } else { rows -= 1 }
        }
        self.columns = columns
        self.rows = rows
    }

    public func label(row: Int, column: Int) -> String {
        let index = row * columns + column
        return String([Self.letters[index / 676], Self.letters[index / 26 % 26], Self.letters[index % 26]])
    }

    public func matches(row: Int, column: Int) -> Bool {
        label(row: row, column: column).hasPrefix(prefix)
    }

    public func cell(row: Int, column: Int) -> CGRect {
        let width = area.width / Double(columns)
        let height = area.height / Double(rows)
        return CGRect(
            x: area.minX + Double(column) * width,
            y: area.minY + Double(row) * height,
            width: width,
            height: height
        )
    }

    public mutating func handle(_ key: Key) -> Outcome {
        switch key {
        case .escape:
            return .cancel
        case .backspace:
            if !prefix.isEmpty { prefix.removeLast() }
            return .pending
        case .other:
            return .pending
        case let .letter(letter, modifiers):
            guard Self.letters.contains(letter) else { return .pending }
            let candidate = prefix + String(letter)
            let start = candidate.reduce(0) { $0 * 26 + Self.letters.firstIndex(of: $1)! }
                * Int(pow(26.0, Double(3 - candidate.count)))
            guard start < rows * columns else { return .pending }
            prefix = candidate
            guard prefix.count == 3 else { return .pending }
            let cell = cell(row: start / columns, column: start % columns)
            prefix = ""
            let button: Button = modifiers.contains(.command) ? .middle
                : modifiers.contains(.shift) ? .right
                : .left
            return .click(CGPoint(x: cell.midX, y: cell.midY), button)
        }
    }
}

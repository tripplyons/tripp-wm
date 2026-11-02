import CoreGraphics

/// Window server ID of a window.
public typealias WindowID = UInt32
/// Core Graphics display ID.
public typealias MonitorID = UInt32

public enum Direction: String, Sendable, CaseIterable {
    case left, right, up, down
}

/// A display in global coordinates with the origin at the top-left corner of
/// the primary display, as used by Accessibility and Core Graphics.
public struct Monitor: Equatable, Sendable {
    public let id: MonitorID
    public let frame: CGRect
    /// The frame without the menu bar and Dock.
    public let visibleFrame: CGRect

    public init(id: MonitorID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// A vertical stack of windows in the scrolling strip.
public struct Column: Equatable, Sendable {
    public var windows: [WindowID]
    public var focusedIndex = 0
    /// Fraction of the monitor width.
    public var width: Double
    public var isFullWidth = false

    public init(windows: [WindowID], width: Double) {
        self.windows = windows
        self.width = width
    }

    public var focusedWindow: WindowID { windows[focusedIndex] }
}

public struct Workspace: Equatable, Sendable {
    public let name: String
    public var columns: [Column] = []
    public var floating: [WindowID] = []
    public var focusedColumn = 0
    /// The focused floating window, or nil when a tiled window has focus.
    public var focusedFloating: WindowID?
    /// Strip position of the monitor's left edge, in points.
    public var viewOffset: Double = 0
    public var lastMonitor: MonitorID?

    public init(name: String) {
        self.name = name
    }

    public var focusedWindow: WindowID? {
        if let focusedFloating {
            return focusedFloating
        }
        guard columns.indices.contains(focusedColumn) else {
            return nil
        }
        return columns[focusedColumn].focusedWindow
    }

    public var allWindows: [WindowID] {
        columns.flatMap(\.windows) + floating
    }

    public var isEmpty: Bool { columns.isEmpty && floating.isEmpty }

    func position(of id: WindowID) -> (column: Int, row: Int)? {
        for (column, entry) in columns.enumerated() {
            if let row = entry.windows.firstIndex(of: id) {
                return (column, row)
            }
        }
        return nil
    }
}

/// Where the window manager wants a window.
public enum Placement: Equatable, Sendable {
    case tiled(CGRect)
    /// Visible at a frame the user chooses.
    case floating
    /// Parked offscreen because its workspace is not shown.
    case hidden(HideCorner)
}

/// The corner where hidden windows wait. Windows keep one point on screen
/// because macOS pulls fully offscreen windows back.
public enum HideCorner: Equatable, Sendable {
    /// Put the window's top-left corner at this point.
    case bottomRight(CGPoint)
    /// Put the window's top-right corner at this point.
    case bottomLeft(CGPoint)

    public func origin(for size: CGSize) -> CGPoint {
        switch self {
        case let .bottomRight(point):
            return point
        case let .bottomLeft(point):
            return CGPoint(x: point.x - size.width, y: point.y)
        }
    }
}

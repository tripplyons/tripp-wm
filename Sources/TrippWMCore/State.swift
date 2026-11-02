import CoreGraphics

public struct LayoutSettings: Equatable, Sendable {
    /// Space between columns, between stacked windows, and at screen edges.
    public var gaps: Double
    public var columnWidths: [Double]
    public var defaultColumnWidth: Double

    public init(
        gaps: Double = 8,
        columnWidths: [Double] = [1.0 / 3, 0.5, 2.0 / 3, 1],
        defaultColumnWidth: Double = 0.5
    ) {
        self.gaps = gaps
        self.columnWidths = columnWidths
        self.defaultColumnWidth = defaultColumnWidth
    }
}

/// Workspaces, columns, and focus for every monitor. Each monitor shows one
/// workspace; the others are hidden. Focus follows what macOS reports, and
/// commands change it in the model for the window backend to apply.
public struct WMState: Sendable {
    public var settings: LayoutSettings
    public private(set) var monitors: [Monitor] = []
    public private(set) var workspaces: [Workspace]
    public private(set) var visible: [MonitorID: String] = [:]
    public private(set) var focusedMonitor: MonitorID?
    public private(set) var previousWorkspace: String?

    public init(
        workspaceNames: [String] = (1...9).map(String.init),
        settings: LayoutSettings = LayoutSettings()
    ) {
        precondition(!workspaceNames.isEmpty)
        workspaces = workspaceNames.map(Workspace.init(name:))
        self.settings = settings
    }

    // MARK: Queries

    public var focusedWorkspaceName: String? {
        focusedMonitor.flatMap { visible[$0] }
    }

    public var focusedWindow: WindowID? {
        focusedWorkspaceName.flatMap { workspace(named: $0)?.focusedWindow }
    }

    public func workspace(named name: String) -> Workspace? {
        workspaces.first { $0.name == name }
    }

    public func workspaceName(of id: WindowID) -> String? {
        workspaces.first { $0.allWindows.contains(id) }?.name
    }

    public func contains(_ id: WindowID) -> Bool {
        workspaceName(of: id) != nil
    }

    public func isFloating(_ id: WindowID) -> Bool {
        workspaces.contains { $0.floating.contains(id) }
    }

    public func monitor(showing name: String) -> MonitorID? {
        visible.first { $0.value == name }?.key
    }

    // MARK: Monitors

    /// Keeps each remaining monitor's workspace and gives new monitors the
    /// workspace they last showed, or the first workspace not shown elsewhere.
    public mutating func setMonitors(_ newMonitors: [Monitor]) {
        monitors = newMonitors.sorted {
            ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY)
        }
        var assigned: [MonitorID: String] = [:]
        for monitor in monitors {
            if let name = visible[monitor.id] {
                assigned[monitor.id] = name
            }
        }
        for monitor in monitors where assigned[monitor.id] == nil {
            let used = Set(assigned.values)
            let free = workspaces.filter { !used.contains($0.name) }
            let name = free.first { $0.lastMonitor == monitor.id }?.name ?? free.first?.name
            assigned[monitor.id] = name
        }
        visible = assigned
        for (monitor, name) in visible {
            update(name) { $0.lastMonitor = monitor }
        }
        if focusedMonitor.map({ id in !monitors.contains { $0.id == id } }) ?? true {
            focusedMonitor = monitors.first?.id
        }
    }

    // MARK: Windows

    /// Adds a window without focusing it; macOS reports focus separately.
    /// Without a workspace, the window joins the workspace shown on `monitor`,
    /// or else the focused workspace.
    public mutating func addWindow(
        _ id: WindowID,
        floating: Bool = false,
        workspace requested: String? = nil,
        monitor: MonitorID? = nil,
        atEnd: Bool = false
    ) {
        guard !contains(id) else {
            return
        }
        let name = requested.flatMap { self.workspace(named: $0)?.name }
            ?? monitor.flatMap { visible[$0] }
            ?? focusedWorkspaceName
            ?? workspaces[0].name
        let width = settings.defaultColumnWidth
        update(name) { workspace in
            if floating {
                workspace.floating.append(id)
            } else {
                let index = atEnd || workspace.columns.isEmpty
                    ? workspace.columns.count
                    : workspace.focusedColumn + 1
                workspace.columns.insert(Column(windows: [id], width: width), at: index)
                if index <= workspace.focusedColumn, workspace.columns.count > 1 {
                    workspace.focusedColumn += 1
                }
            }
        }
    }

    public mutating func removeWindow(_ id: WindowID) {
        guard let name = workspaceName(of: id) else {
            return
        }
        update(name) { Self.detach(id, from: &$0) }
    }

    /// Focuses a window that macOS or the pointer selected, showing its
    /// workspace when it was hidden. Scrolling is off for pointer focus so
    /// that the strip does not move under a resting pointer.
    public mutating func focus(_ id: WindowID, scroll: Bool = true) {
        guard let name = workspaceName(of: id) else {
            return
        }
        if let monitor = monitor(showing: name) {
            focusedMonitor = monitor
        } else {
            show(name)
        }
        update(name) { workspace in
            if workspace.floating.contains(id) {
                workspace.focusedFloating = id
            } else if let (column, row) = workspace.position(of: id) {
                workspace.focusedFloating = nil
                workspace.focusedColumn = column
                workspace.columns[column].focusedIndex = row
            }
        }
        if scroll {
            scrollToFocus(name)
        }
    }

    /// Sets the width of a window's column from a width in points, after the
    /// user resizes a tiled window by hand.
    public mutating func setColumnWidth(of id: WindowID, points: Double) {
        guard let name = workspaceName(of: id), let area = area(for: name) else {
            return
        }
        let gaps = settings.gaps
        let fraction = min(1, max(0.05, (points + gaps) / (area.width - gaps)))
        update(name) { workspace in
            guard let (column, _) = workspace.position(of: id) else {
                return
            }
            workspace.columns[column].width = fraction
            workspace.columns[column].isFullWidth = false
        }
        scrollToFocus(name)
    }

    // MARK: Commands

    /// Runs a layout command. `reloadConfig`, `grid`, and `exec` belong to the
    /// app and do nothing here.
    public mutating func perform(_ command: Command) {
        guard let name = focusedWorkspaceName else {
            return
        }
        switch command {
        case let .focus(direction):
            update(name) { Self.moveFocus(direction, in: &$0) }
        case let .move(direction):
            update(name) { Self.moveWindow(direction, in: &$0) }
        case let .consumeOrExpel(direction):
            let width = settings.defaultColumnWidth
            update(name) { Self.consumeOrExpel(direction, width: width, in: &$0) }
        case .cycleWidth:
            let presets = settings.columnWidths.sorted()
            update(name) { workspace in
                guard workspace.focusedFloating == nil,
                      workspace.columns.indices.contains(workspace.focusedColumn)
                else { return }
                var column = workspace.columns[workspace.focusedColumn]
                let current = column.isFullWidth ? 1 : column.width
                column.width = presets.first { $0 > current + 0.01 } ?? presets.first ?? current
                column.isFullWidth = false
                workspace.columns[workspace.focusedColumn] = column
            }
        case .maximizeColumn:
            update(name) { workspace in
                guard workspace.focusedFloating == nil,
                      workspace.columns.indices.contains(workspace.focusedColumn)
                else { return }
                workspace.columns[workspace.focusedColumn].isFullWidth.toggle()
            }
        case .centerColumn:
            center(name)
            return
        case .toggleFloat:
            let width = settings.defaultColumnWidth
            update(name) { Self.toggleFloat(width: width, in: &$0) }
        case let .workspace(target):
            show(target)
        case .workspaceNext:
            stepWorkspace(by: 1)
        case .workspacePrevious:
            stepWorkspace(by: -1)
        case .workspaceBackAndForth:
            if let previousWorkspace {
                show(previousWorkspace)
            }
        case let .moveToWorkspace(target):
            moveFocusedWindow(to: target)
        case .reloadConfig, .grid, .exec:
            return
        }
        if let current = focusedWorkspaceName {
            scrollToFocus(current)
        }
    }

    // MARK: Layout

    /// Frames for every window. Columns that leave the monitor are hidden when
    /// another monitor would show them, and fully offscreen columns are hidden.
    /// Set `parkingOffscreen` to false to get the strip frames used during
    /// transitions. Windows on inactive workspaces remain hidden either way.
    public func layout(parkingOffscreen: Bool = true) -> [WindowID: Placement] {
        var placements: [WindowID: Placement] = [:]
        for workspace in workspaces {
            let monitor = monitor(showing: workspace.name).flatMap(monitor(withID:))
            guard let monitor else {
                let corner = hideCorner(for: workspace)
                for id in workspace.allWindows {
                    placements[id] = .hidden(corner)
                }
                continue
            }
            let area = monitor.visibleFrame
            let strip = Strip(workspace: workspace, area: area, gaps: settings.gaps)
            let offset = strip.clamp(workspace.viewOffset)
            let corner = hideCorner(for: monitor)
            let gaps = settings.gaps
            for (index, column) in workspace.columns.enumerated() {
                let x = area.minX + strip.positions[index] - offset
                let width = strip.widths[index]
                let tolerance = 0.5
                let offLeft = x < area.minX - tolerance
                let offRight = x + width > area.maxX + tolerance
                let outside = x + width <= area.minX || x >= area.maxX
                if parkingOffscreen && (outside
                    || (offLeft && hasNeighbor(of: monitor, on: .left))
                    || (offRight && hasNeighbor(of: monitor, on: .right)))
                {
                    for id in column.windows {
                        placements[id] = .hidden(corner)
                    }
                    continue
                }
                let count = Double(column.windows.count)
                let height = max(1, (area.height - gaps * (count + 1)) / count)
                for (row, id) in column.windows.enumerated() {
                    let y = area.minY + gaps + Double(row) * (height + gaps)
                    placements[id] = .tiled(CGRect(x: x, y: y, width: width, height: height))
                }
            }
            for id in workspace.floating {
                placements[id] = .floating
            }
        }
        return placements
    }

    public func monitor(withID id: MonitorID) -> Monitor? {
        monitors.first { $0.id == id }
    }

    // MARK: Private helpers

    private mutating func update(_ name: String, _ change: (inout Workspace) -> Void) {
        guard let index = workspaces.firstIndex(where: { $0.name == name }) else {
            return
        }
        change(&workspaces[index])
    }

    /// Shows a workspace on the focused monitor, or focuses the monitor that
    /// already shows it.
    private mutating func show(_ name: String) {
        guard workspace(named: name) != nil,
              let monitor = focusedMonitor,
              let current = visible[monitor],
              current != name
        else { return }
        previousWorkspace = current
        if let other = self.monitor(showing: name) {
            focusedMonitor = other
            return
        }
        visible[monitor] = name
        update(name) { $0.lastMonitor = monitor }
    }

    private mutating func stepWorkspace(by step: Int) {
        guard let current = focusedWorkspaceName,
              var index = workspaces.firstIndex(where: { $0.name == current })
        else { return }
        while true {
            index += step
            guard workspaces.indices.contains(index) else {
                return
            }
            let name = workspaces[index].name
            if monitor(showing: name) == nil {
                show(name)
                return
            }
        }
    }

    private mutating func moveFocusedWindow(to target: String) {
        guard let current = focusedWorkspaceName,
              current != target,
              workspace(named: target) != nil,
              let id = focusedWindow
        else { return }
        let floating = isFloating(id)
        update(current) { Self.detach(id, from: &$0) }
        addWindow(id, floating: floating, workspace: target)
        // Focus the window there so it is selected when that workspace shows.
        update(target) { workspace in
            if floating {
                workspace.focusedFloating = id
            } else if let (column, _) = workspace.position(of: id) {
                workspace.focusedFloating = nil
                workspace.focusedColumn = column
            }
        }
    }

    private mutating func scrollToFocus(_ name: String) {
        guard let area = area(for: name) else {
            return
        }
        let gaps = settings.gaps
        update(name) { workspace in
            let strip = Strip(workspace: workspace, area: area, gaps: gaps)
            guard workspace.focusedFloating == nil,
                  strip.positions.indices.contains(workspace.focusedColumn)
            else {
                workspace.viewOffset = strip.clamp(workspace.viewOffset)
                return
            }
            let left = strip.positions[workspace.focusedColumn] - gaps
            let right = left + strip.widths[workspace.focusedColumn] + 2 * gaps
            var offset = workspace.viewOffset
            if right - left >= area.width || left < offset {
                offset = left
            } else if right > offset + area.width {
                offset = right - area.width
            }
            workspace.viewOffset = strip.clamp(offset)
        }
    }

    private mutating func center(_ name: String) {
        guard let area = area(for: name) else {
            return
        }
        let gaps = settings.gaps
        update(name) { workspace in
            let strip = Strip(workspace: workspace, area: area, gaps: gaps)
            guard strip.positions.indices.contains(workspace.focusedColumn) else {
                return
            }
            let middle = strip.positions[workspace.focusedColumn]
                + strip.widths[workspace.focusedColumn] / 2
            workspace.viewOffset = strip.clamp(middle - area.width / 2)
        }
    }

    private func area(for name: String) -> CGRect? {
        let id = monitor(showing: name) ?? workspace(named: name)?.lastMonitor ?? focusedMonitor
        return id.flatMap(monitor(withID:))?.visibleFrame
    }

    private func hideCorner(for workspace: Workspace) -> HideCorner {
        let monitor = workspace.lastMonitor.flatMap(monitor(withID:)) ?? monitors.first
        guard let monitor else {
            return .bottomRight(.zero)
        }
        return hideCorner(for: monitor)
    }

    /// The bottom corner of a monitor that no other monitor touches.
    func hideCorner(for monitor: Monitor) -> HideCorner {
        let frame = monitor.frame
        let far = 100_000.0
        let others = monitors.filter { $0.id != monitor.id }
        let right = CGRect(x: frame.maxX - 1, y: frame.maxY - 1, width: far, height: far)
        if !others.contains(where: { $0.frame.intersects(right) }) {
            return .bottomRight(CGPoint(x: frame.maxX - 1, y: frame.maxY - 1))
        }
        let left = CGRect(x: frame.minX + 1 - far, y: frame.maxY - 1, width: far, height: far)
        if !others.contains(where: { $0.frame.intersects(left) }) {
            return .bottomLeft(CGPoint(x: frame.minX + 1, y: frame.maxY - 1))
        }
        return .bottomRight(CGPoint(x: frame.maxX - 1, y: frame.maxY - 1))
    }

    private func hasNeighbor(of monitor: Monitor, on side: Direction) -> Bool {
        let frame = monitor.frame
        return monitors.contains { other in
            guard other.id != monitor.id,
                  other.frame.maxY > frame.minY,
                  other.frame.minY < frame.maxY
            else { return false }
            switch side {
            case .left: return other.frame.maxX <= frame.minX + 1
            case .right: return other.frame.minX >= frame.maxX - 1
            case .up, .down: return false
            }
        }
    }

    // MARK: Workspace edits

    /// Removes a window and moves focus to the window below it, or to the
    /// column on the left when its column closes.
    private static func detach(_ id: WindowID, from workspace: inout Workspace) {
        if let index = workspace.floating.firstIndex(of: id) {
            workspace.floating.remove(at: index)
            if workspace.focusedFloating == id {
                workspace.focusedFloating = nil
            }
            return
        }
        guard let (column, row) = workspace.position(of: id) else {
            return
        }
        workspace.columns[column].windows.remove(at: row)
        if workspace.columns[column].windows.isEmpty {
            workspace.columns.remove(at: column)
            if column < workspace.focusedColumn
                || (column == workspace.focusedColumn && column > 0)
            {
                workspace.focusedColumn -= 1
            }
            workspace.focusedColumn = min(workspace.focusedColumn, max(0, workspace.columns.count - 1))
            return
        }
        let count = workspace.columns[column].windows.count
        var focused = workspace.columns[column].focusedIndex
        if row < focused {
            focused -= 1
        }
        workspace.columns[column].focusedIndex = min(focused, count - 1)
    }

    private static func moveFocus(_ direction: Direction, in workspace: inout Workspace) {
        if workspace.focusedFloating != nil {
            // Leave the floating layer for the tiled window under it.
            if !workspace.columns.isEmpty {
                workspace.focusedFloating = nil
            }
            return
        }
        guard workspace.columns.indices.contains(workspace.focusedColumn) else {
            return
        }
        switch direction {
        case .left:
            workspace.focusedColumn = max(0, workspace.focusedColumn - 1)
        case .right:
            workspace.focusedColumn = min(workspace.columns.count - 1, workspace.focusedColumn + 1)
        case .up, .down:
            var column = workspace.columns[workspace.focusedColumn]
            let step = direction == .up ? -1 : 1
            column.focusedIndex = min(max(0, column.focusedIndex + step), column.windows.count - 1)
            workspace.columns[workspace.focusedColumn] = column
        }
    }

    private static func moveWindow(_ direction: Direction, in workspace: inout Workspace) {
        guard workspace.focusedFloating == nil,
              workspace.columns.indices.contains(workspace.focusedColumn)
        else { return }
        let index = workspace.focusedColumn
        switch direction {
        case .left, .right:
            let target = index + (direction == .left ? -1 : 1)
            guard workspace.columns.indices.contains(target) else {
                return
            }
            workspace.columns.swapAt(index, target)
            workspace.focusedColumn = target
        case .up, .down:
            var column = workspace.columns[index]
            let target = column.focusedIndex + (direction == .up ? -1 : 1)
            guard column.windows.indices.contains(target) else {
                return
            }
            column.windows.swapAt(column.focusedIndex, target)
            column.focusedIndex = target
            workspace.columns[index] = column
        }
    }

    private static func consumeOrExpel(
        _ direction: Direction,
        width: Double,
        in workspace: inout Workspace
    ) {
        guard workspace.focusedFloating == nil,
              workspace.columns.indices.contains(workspace.focusedColumn),
              direction == .left || direction == .right
        else { return }
        let index = workspace.focusedColumn
        var column = workspace.columns[index]
        let id = column.focusedWindow
        if column.windows.count > 1 {
            column.windows.remove(at: column.focusedIndex)
            column.focusedIndex = min(column.focusedIndex, column.windows.count - 1)
            workspace.columns[index] = column
            let target = direction == .left ? index : index + 1
            workspace.columns.insert(Column(windows: [id], width: width), at: target)
            workspace.focusedColumn = target
            return
        }
        let target = index + (direction == .left ? -1 : 1)
        guard workspace.columns.indices.contains(target) else {
            return
        }
        workspace.columns[target].windows.append(id)
        workspace.columns[target].focusedIndex = workspace.columns[target].windows.count - 1
        workspace.columns.remove(at: index)
        workspace.focusedColumn = direction == .left ? target : target - 1
    }

    private static func toggleFloat(width: Double, in workspace: inout Workspace) {
        if let id = workspace.focusedFloating {
            workspace.floating.removeAll { $0 == id }
            workspace.focusedFloating = nil
            let index = workspace.columns.isEmpty ? 0 : workspace.focusedColumn + 1
            workspace.columns.insert(Column(windows: [id], width: width), at: index)
            workspace.focusedColumn = index
            return
        }
        guard let id = workspace.focusedWindow else {
            return
        }
        detach(id, from: &workspace)
        workspace.floating.append(id)
        workspace.focusedFloating = id
    }
}

/// Column positions along a workspace's strip, measured from its left edge.
struct Strip {
    var positions: [Double] = []
    var widths: [Double] = []
    var length: Double
    let viewWidth: Double

    init(workspace: Workspace, area: CGRect, gaps: Double) {
        viewWidth = area.width
        var x = gaps
        for column in workspace.columns {
            let fraction = column.isFullWidth ? 1 : column.width
            let width = max(1, (area.width - gaps) * fraction - gaps)
            positions.append(x)
            widths.append(width)
            x += width + gaps
        }
        length = x
    }

    func clamp(_ offset: Double) -> Double {
        min(max(0, offset), max(0, length - viewWidth))
    }
}

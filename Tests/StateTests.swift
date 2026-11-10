import CoreGraphics
import Testing
import TrippWMCore

private let screen = Monitor(
    id: 1,
    frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
    visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 600)
)

private func makeState(windows: [WindowID] = []) -> WMState {
    var state = WMState(settings: LayoutSettings(gaps: 10))
    state.setMonitors([screen])
    for id in windows {
        state.addWindow(id)
        state.focus(id)
    }
    return state
}

private func frame(_ state: WMState, _ id: WindowID) -> CGRect? {
    if case let .tiled(rect) = state.layout()[id] {
        return rect
    }
    return nil
}

private func isHidden(_ state: WMState, _ id: WindowID) -> Bool {
    if case .hidden = state.layout()[id] {
        return true
    }
    return false
}

struct StateTests {
    @Test
    func newWindowsOpenRightOfTheFocusedColumn() {
        var state = makeState(windows: [1, 2])
        state.focus(1)
        state.addWindow(3)
        #expect(state.workspace(named: "1")?.columns.map(\.windows) == [[1], [3], [2]])
        #expect(state.focusedWindow == 1)
    }

    @Test
    func halfWidthColumnsFillTheScreenWithGaps() {
        let state = makeState(windows: [1, 2])
        #expect(frame(state, 1) == CGRect(x: 10, y: 10, width: 485, height: 580))
        #expect(frame(state, 2) == CGRect(x: 505, y: 10, width: 485, height: 580))
    }

    @Test
    func focusScrollsTheStripAndHidesColumnsOffscreen() {
        var state = makeState(windows: [1, 2, 3])
        #expect(isHidden(state, 1))
        #expect(frame(state, 2)?.minX == 10)
        #expect(frame(state, 3)?.minX == 505)

        state.perform(.focus(.left))
        state.perform(.focus(.left))
        #expect(state.focusedWindow == 1)
        #expect(frame(state, 1)?.minX == 10)
        #expect(isHidden(state, 3))
    }

    @Test
    func offscreenTransitionsKeepTheStripGeometry() throws {
        var state = makeState(windows: [1, 2, 3])
        let before = state.layout(parkingOffscreen: false)
        #expect(isHidden(state, 1))
        guard case let .tiled(enteringStart)? = before[1],
              case let .tiled(leavingStart)? = before[3] else {
            Issue.record("Active strip must include offscreen frames")
            return
        }
        #expect(enteringStart.maxX <= screen.visibleFrame.minX)
        state.focus(1)
        let after = state.layout(parkingOffscreen: false)
        guard case let .tiled(enteringEnd)? = after[1],
              case let .tiled(leavingEnd)? = after[3] else {
            Issue.record("Active strip must retain departing frames")
            return
        }
        #expect(isHidden(state, 3))
        #expect(leavingEnd.minX >= screen.visibleFrame.maxX)
        #expect(enteringStart.minY == enteringEnd.minY)
        #expect(leavingStart.minY == leavingEnd.minY)
        #expect(enteringEnd.minX - enteringStart.minX == leavingEnd.minX - leavingStart.minX)
        let settings = AnimationSettings()
        let entering = FrameAnimation(from: enteringStart, to: enteringEnd, start: 0, settings: settings)
        let leaving = FrameAnimation(from: leavingStart, to: leavingEnd, start: 0, settings: settings)
        #expect(entering.frame(at: 0.09).minX - enteringStart.minX
            == leaving.frame(at: 0.09).minX - leavingStart.minX)
        #expect(entering.frame(at: 0.09).minY == enteringEnd.minY)
        state.perform(.workspace("2"))
        for id: WindowID in [1, 2, 3] {
            guard case .hidden? = state.layout(parkingOffscreen: false)[id] else {
                Issue.record("Inactive workspaces must remain parked")
                continue
            }
        }
    }

    @Test
    func centerColumnPutsTheFocusedColumnInTheMiddle() {
        var state = makeState(windows: [1, 2, 3])
        state.perform(.focus(.left))
        state.perform(.centerColumn)
        #expect(frame(state, 2)?.midX == 500)
    }

    @Test
    func stackedWindowsShareTheColumnHeight() {
        var state = makeState(windows: [1, 2])
        state.perform(.consumeOrExpel(.left))
        #expect(state.workspace(named: "1")?.columns.map(\.windows) == [[1, 2]])
        #expect(frame(state, 1) == CGRect(x: 10, y: 10, width: 485, height: 285))
        #expect(frame(state, 2) == CGRect(x: 10, y: 305, width: 485, height: 285))

        state.perform(.focus(.up))
        #expect(state.focusedWindow == 1)
        state.perform(.consumeOrExpel(.right))
        #expect(state.workspace(named: "1")?.columns.map(\.windows) == [[2], [1]])
        #expect(state.focusedWindow == 1)
    }

    @Test
    func moveSwapsColumnsAndWindows() {
        var state = makeState(windows: [1, 2])
        state.perform(.move(.left))
        #expect(state.workspace(named: "1")?.columns.map(\.windows) == [[2], [1]])
        #expect(state.focusedWindow == 2)
    }

    @Test
    func widthPresetsCycleAndMaximizeToggles() {
        var state = makeState(windows: [1])
        state.perform(.cycleWidth)
        #expect(frame(state, 1)?.width == 650)
        state.perform(.cycleWidth)
        state.perform(.cycleWidth)
        #expect(frame(state, 1)?.width == 320)
        state.perform(.maximizeColumn)
        #expect(frame(state, 1)?.width == 980)
        state.perform(.maximizeColumn)
        #expect(frame(state, 1)?.width == 320)
    }

    @Test
    func resizingATiledWindowSetsItsColumnWidth() {
        var state = makeState(windows: [1, 2])
        state.setColumnWidth(of: 1, points: 287)
        #expect(frame(state, 1).map { $0.width.rounded() } == 287)
        #expect(frame(state, 2).map { $0.minX.rounded() } == 307)
    }

    @Test
    func closingAWindowFocusesItsLeftNeighbor() {
        var state = makeState(windows: [1, 2, 3])
        state.perform(.focus(.left))
        state.removeWindow(2)
        #expect(state.focusedWindow == 1)
        state.removeWindow(1)
        #expect(state.focusedWindow == 3)
    }

    @Test
    func workspacesHideTheirWindowsWhenNotShown() {
        var state = makeState(windows: [1])
        state.perform(.workspace("2"))
        #expect(state.focusedWorkspaceName == "2")
        #expect(state.layout()[1] == .hidden(.bottomRight(CGPoint(x: 999, y: 599))))

        state.addWindow(2)
        state.perform(.workspaceBackAndForth)
        #expect(state.focusedWorkspaceName == "1")
        #expect(frame(state, 1) != nil)
        #expect(isHidden(state, 2))
    }

    @Test
    func workspaceCycleShowsTheFirstOrNextListedWorkspace() {
        var state = makeState(windows: [1])
        state.perform(.workspace("3"))
        state.perform(.workspaceCycle(["1", "2"]))
        #expect(state.focusedWorkspaceName == "1")
        state.perform(.workspaceCycle(["1", "2"]))
        #expect(state.focusedWorkspaceName == "2")
        state.perform(.workspaceCycle(["1", "2"]))
        #expect(state.focusedWorkspaceName == "1")
    }

    @Test
    func focusingAHiddenWindowShowsItsWorkspace() {
        var state = makeState(windows: [1])
        state.perform(.workspace("3"))
        state.focus(1)
        #expect(state.focusedWorkspaceName == "1")
    }

    @Test
    func movingAWindowToAWorkspaceLeavesFocusBehind() {
        var state = makeState(windows: [1, 2])
        state.perform(.moveToWorkspace("4"))
        #expect(state.workspaceName(of: 2) == "4")
        #expect(state.focusedWorkspaceName == "1")
        #expect(state.focusedWindow == 1)
        state.perform(.workspace("4"))
        #expect(state.focusedWindow == 2)
    }

    @Test
    func floatingWindowsLeaveTheStrip() {
        var state = makeState(windows: [1, 2])
        state.perform(.toggleFloat)
        #expect(state.isFloating(2))
        #expect(state.layout()[2] == .floating)
        #expect(state.workspace(named: "1")?.columns.map(\.windows) == [[1]])
        state.perform(.toggleFloat)
        #expect(state.workspace(named: "1")?.columns.map(\.windows) == [[1], [2]])
    }

    @Test
    func workspaceNextSkipsWorkspacesOnOtherMonitors() {
        let right = Monitor(
            id: 2,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 600),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 600)
        )
        var state = WMState(settings: LayoutSettings(gaps: 10))
        state.setMonitors([right, screen])
        #expect(state.monitor(showing: "1") == 1)
        #expect(state.monitor(showing: "2") == 2)
        #expect(state.focusedMonitor == 1)

        state.perform(.workspace("2"))
        #expect(state.focusedMonitor == 2)
        state.perform(.workspaceNext)
        #expect(state.focusedWorkspaceName == "3")
        #expect(state.monitor(showing: "1") == 1)
    }

    @Test
    func columnsSpillingTowardANeighborMonitorAreHidden() {
        let right = Monitor(
            id: 2,
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 600),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 600)
        )
        var state = WMState(settings: LayoutSettings(gaps: 10, defaultColumnWidth: 0.6))
        state.setMonitors([screen, right])
        state.addWindow(1, monitor: 1)
        state.addWindow(2, monitor: 1)
        state.focus(1)
        #expect(frame(state, 1) != nil)
        #expect(state.layout()[2] == .hidden(.bottomLeft(CGPoint(x: 1, y: 599))))

        state.setMonitors([screen])
        #expect(frame(state, 2) != nil)
    }
}

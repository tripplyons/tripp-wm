import AppKit
import ApplicationServices
import TrippWMCore

/// AX elements are immutable references. Each app's worker serializes their
/// writes, and layout boundaries drain workers before accessing real frames.
private struct AnimationFrameUpdate: @unchecked Sendable {
    let id: WindowID
    let element: AXUIElement
    let target: CGRect
}

/// Accessed only by its owning worker queue.
private final class AnimationFrameCache: @unchecked Sendable {
    var frames: [WindowID: CGRect]

    init(frames: [WindowID: CGRect]) {
        self.frames = frames
    }
}

/// Applies `WMState` to real windows through Accessibility and feeds it the
/// window and focus events that macOS reports.
@MainActor
final class WindowManager {
    private struct TrackedApp {
        let element: AXUIElement
        let observer: AXObserver
        let bundleID: String?
        let name: String?
    }

    private struct TrackedWindow {
        let element: AXUIElement
        let pid: pid_t
        /// Parked offscreen because its workspace is hidden.
        var parked = false
        /// Where a floating window was before it was parked.
        var floatingFrame: CGRect?
        /// Minimized or in a hidden app; out of the layout until it returns.
        var suspendedWorkspace: String?
    }

    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
    ]

    /// Focus events for other windows arrive late after a focus change, so
    /// they are ignored for this long.
    private static let focusSettleTime: TimeInterval = 0.4

    private(set) var isEnabled = true
    private(set) var state: WMState
    private var config: Config
    private var apps: [pid_t: TrackedApp] = [:]
    private var windows: [WindowID: TrackedWindow] = [:]
    private var pendingFocus: (id: WindowID?, until: Date)?
    private let border = Border()
    private var actionModeOn = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var unlistedAppTimer: Timer?
    private let animationClock = AnimationClock()
    private var animations: [WindowID: FrameAnimation] = [:]
    private var animationFrames: [WindowID: CGRect] = [:]
    private var animationSessions: [pid_t: ApplicationAnimationSession] = [:]
    private var frameWriters: [pid_t: LatestValueWorker<[AnimationFrameUpdate]>] = [:]
    private var borderFrontmostPID: pid_t?
    private var stripLayout: [WindowID: Placement] = [:]

    /// Called after every layout so the status item can show the workspace.
    var onChange: (() -> Void)?

    init(config: Config) {
        self.config = config
        state = WMState(workspaceNames: Config.workspaceNames, settings: config.layout)
    }

    // MARK: Lifecycle

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        state.setMonitors(Screens.monitors())
        observeWorkspace()

        // Keep the current left-to-right order of existing windows.
        var found: [(id: WindowID, x: CGFloat)] = []
        for app in NSWorkspace.shared.runningApplications {
            track(app)
        }
        trackUnlistedApps()
        for pid in apps.keys {
            for element in apps[pid]?.element.windows ?? [] {
                if let id = adopt(element, pid: pid, add: false),
                   windows[id]?.suspendedWorkspace == nil
                {
                    found.append((id, element.frame?.minX ?? 0))
                }
            }
        }
        for (id, _) in found.sorted(by: { $0.x < $1.x }) {
            addToState(id, atEnd: true)
        }
        syncFocus()
        apply(focus: false)

        unlistedAppTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for pid in self.trackUnlistedApps() {
                    self.scan(pid)
                }
            }
        }
    }

    /// Brings parked windows back on screen so they stay reachable after quit.
    func restoreWindows() {
        stopAnimations()
        let area = state.focusedMonitor.flatMap(state.monitor(withID:))?.visibleFrame
            ?? Screens.monitors().first?.visibleFrame
            ?? .zero
        for window in windows.values where window.parked {
            let origin = window.floatingFrame?.origin
                ?? CGPoint(x: area.minX + 40, y: area.minY + 40)
            window.element.setPosition(origin)
        }
    }

    /// Keep observing window lifetimes while disabled, but leave windows alone.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        pendingFocus = nil
        if enabled {
            for pid in apps.keys {
                scan(pid)
            }
            syncFocus()
            apply(focus: false)
        } else {
            restoreWindows()
            for id in Array(windows.keys) {
                windows[id]?.parked = false
            }
            border.hide()
        }
        onChange?()
    }

    /// Shows the action mode through the border color.
    func setActionMode(_ isOn: Bool) {
        guard isOn != actionModeOn else { return }
        actionModeOn = isOn
        updateBorder()
    }

    func update(config: Config) {
        self.config = config
        state.settings = config.layout
        apply(focus: false)
    }

    // MARK: Commands and input

    func perform(_ command: Command) {
        guard isEnabled else { return }
        state.perform(command)
        let animation: AnimationSettings?
        switch command {
        case .focus, .centerColumn:
            animation = config.focusAnimation
        case .move, .consumeOrExpel, .cycleWidth, .maximizeColumn:
            animation = config.moveAnimation
        default:
            animation = nil
        }
        apply(focus: true, animation: animation)
    }

    func snapshot() -> Snapshot {
        Snapshot(state: state) { id in
            let window = windows[id]
            return Snapshot.Window(
                id: id,
                app: window.flatMap { apps[$0.pid]?.name },
                title: window?.element.string(kAXTitleAttribute)
            )
        }
    }

    /// Adopts a hand-resized column width and snaps moved windows back.
    func mouseReleased() {
        guard isEnabled else { return }
        if let id = state.focusedWindow,
           case let .tiled(rect)? = state.layout()[id],
           let frame = windows[id]?.element.frame,
           abs(frame.width - rect.width) > 2
        {
            state.setColumnWidth(of: id, points: frame.width)
        }
        apply(focus: false)
    }

    // MARK: Layout

    private func apply(focus: Bool, animation: AnimationSettings? = nil) {
        guard isEnabled else { return }
        discardFrameWrites()
        let previous = animations
        let previousFrames = animationFrames
        // Retarget without restoring and disabling the app's Accessibility mode.
        animationClock.stop()
        animations.removeAll()
        animationFrames.removeAll()
        var newAnimations: Set<WindowID> = []
        let parkedLayout = state.layout()
        let previousStrip = stripLayout
        stripLayout = state.layout(parkingOffscreen: false)
        let animate = animation.map { $0.duration > 0 } ?? false
        for (id, placement) in animate ? stripLayout : parkedLayout {
            guard var window = windows[id] else {
                continue
            }
            switch placement {
            case let .tiled(rect):
                // Windows that remain outside the viewport stay parked. Only
                // entering and departing windows need their natural strip frames.
                if window.parked, case .hidden? = parkedLayout[id] { continue }
                let wasParked = window.parked
                window.parked = false
                if let animation, let pending = previous[id], pending.to == rect,
                   animation.duration > 0 {
                    animations[id] = pending
                    animationFrames[id] = previousFrames[id]
                } else if let animation, animate {
                    let from: CGRect?
                    if wasParked, case let .tiled(frame)? = previousStrip[id] {
                        // Never interpolate from the bottom-corner parking spot.
                        setFrame(frame, of: window)
                        from = window.element.frame
                    } else {
                        // Read the actual frame when interrupted: the app may
                        // have constrained a successful Accessibility request.
                        from = window.element.frame
                    }
                    if let from, from != rect {
                        // The start time is assigned after synchronous layout
                        // and focus work, which can be slow in Chrome.
                        animations[id] = FrameAnimation(from: from, to: rect, start: 0, settings: animation)
                        newAnimations.insert(id)
                        animationFrames[id] = from
                    } else {
                        setFrame(rect, of: window)
                    }
                } else {
                    setFrame(rect, of: window)
                }
            case .floating:
                if window.parked {
                    window.parked = false
                    if let frame = window.floatingFrame {
                        setFrame(frame, of: window)
                    }
                }
            case let .hidden(corner):
                guard let frame = window.element.frame else {
                    break
                }
                if !window.parked {
                    window.parked = true
                    window.floatingFrame = state.isFloating(id) ? frame : nil
                }
                let origin = corner.origin(for: frame.size)
                if abs(frame.minX - origin.x) > 1 || abs(frame.minY - origin.y) > 1 {
                    window.element.setPosition(origin)
                }
            }
            windows[id] = window
        }
        updateAnimationSessions()
        if focus {
            let target = state.focusedWindow
            if target != systemFocusedWindow() {
                focusSystem(on: target)
            }
        }
        updateBorder()
        onChange?()
        let now = ProcessInfo.processInfo.systemUptime
        for id in newAnimations {
            guard let animation = animations[id] else { continue }
            animations[id] = FrameAnimation(
                from: animation.from, to: animation.to, start: now, settings: animation.settings
            )
        }
        if !animations.isEmpty {
            animationClock.start(on: state.focusedMonitor) { [weak self] in
                self?.advanceAnimations()
            }
        }
    }

    /// One Accessibility-mode change per resizing app, shared by all its windows.
    private func updateAnimationSessions() {
        let resizingApps = Set(animations.compactMap { id, animation -> pid_t? in
            guard abs(animation.from.width - animation.to.width) > 1
                || abs(animation.from.height - animation.to.height) > 1
            else { return nil }
            return windows[id]?.pid
        })
        for pid in Array(animationSessions.keys) where !resizingApps.contains(pid) {
            animationSessions.removeValue(forKey: pid)?.finish()
        }
        for pid in resizingApps where animationSessions[pid] == nil {
            if let app = apps[pid] {
                animationSessions[pid] = ApplicationAnimationSession(backend: app.element)
            }
        }
    }

    private func stopAnimations() {
        animationClock.stop()
        discardFrameWrites()
        animations.removeAll()
        animationFrames.removeAll()
        for session in animationSessions.values { session.finish() }
        animationSessions.removeAll()
    }

    private func discardFrameWrites() {
        for writer in frameWriters.values { writer.cancel() }
        for writer in frameWriters.values { writer.wait() }
        frameWriters.removeAll()
    }

    private func writeAnimationFrames(_ updates: [pid_t: [AnimationFrameUpdate]]) {
        for (pid, frames) in updates {
            if frameWriters[pid] == nil {
                // Layout already read these frames before starting the clock.
                // Reading them again here can stall the first write while the
                // border advances, then jump straight to a later pending frame.
                let cache = AnimationFrameCache(frames: Dictionary(uniqueKeysWithValues:
                    frames.compactMap { update in
                        animations[update.id].map { (update.id, $0.from) }
                    }
                ))
                frameWriters[pid] = LatestValueWorker { updates in
                    for update in updates {
                        cache.frames[update.id] = applyWindowFrame(
                            update.target, to: update.element,
                            current: cache.frames[update.id]
                        )
                    }
                }
            }
            frameWriters[pid]?.submit(frames)
        }
    }

    private func advanceAnimations() {
        let now = ProcessInfo.processInfo.systemUptime
        var updates: [pid_t: [AnimationFrameUpdate]] = [:]
        var finished: [(WindowID, FrameAnimation)] = []
        for (id, animation) in animations {
            guard let window = windows[id], window.suspendedWorkspace == nil, !window.parked else {
                animations[id] = nil
                animationFrames[id] = nil
                continue
            }
            let frame = animation.frame(at: now)
            animationFrames[id] = frame
            updates[window.pid, default: []].append(AnimationFrameUpdate(
                id: id, element: window.element, target: frame
            ))
            if animation.isFinished(at: now) {
                finished.append((id, animation))
            }
        }
        writeAnimationFrames(updates)
        if !finished.isEmpty {
            // Reconcile only after the final queued writes have reached apps.
            for writer in frameWriters.values { writer.wait() }
            for (id, animation) in finished {
                animations[id] = nil
                animationFrames[id] = nil
                guard let window = windows[id] else { continue }
                setFrame(animation.to, of: window)
                if case let .hidden(corner)? = state.layout()[id] {
                    window.element.setPosition(corner.origin(for: animation.to.size))
                    windows[id]?.parked = true
                }
            }
        }
        if let focused = state.focusedWindow,
           animationFrames[focused] != nil || finished.contains(where: { $0.0 == focused }) {
            updateBorder(checkFrontmost: false)
        }
        if animations.isEmpty {
            stopAnimations()
        } else {
            updateAnimationSessions()
        }
    }

    @discardableResult
    private func setFrame(_ rect: CGRect, of window: TrackedWindow, current cached: CGRect? = nil) -> CGRect? {
        guard let current = cached ?? window.element.frame else { return nil }
        let resize = abs(current.width - rect.width) > 1 || abs(current.height - rect.height) > 1
        // Animated resizes share a session. Immediate resizes still restore
        // the app's original mode before returning. Pure moves need neither.
        let session: ApplicationAnimationSession?
        if resize, animationSessions[window.pid] == nil, let app = apps[window.pid] {
            session = ApplicationAnimationSession(backend: app.element)
        } else {
            session = nil
        }
        defer { session?.finish() }
        return applyWindowFrame(rect, to: window.element, current: current)
    }

    private func isVisible(_ id: WindowID) -> Bool {
        switch state.layout()[id] {
        case .tiled?, .floating?: return true
        case .hidden?, nil: return false
        }
    }

    private func updateBorder(checkFrontmost: Bool = true) {
        if checkFrontmost { borderFrontmostPID = frontmostPID() }
        guard isEnabled, config.border,
              let id = state.focusedWindow, isVisible(id),
              let window = windows[id],
              let frame = animationFrames[id] ?? window.element.frame
        else {
            border.hide()
            return
        }
        guard borderFrontmostPID == window.pid else {
            // Keep the old outline until a requested app activation completes,
            // so cross-app focus changes can glide from it instead of snapping.
            if let pending = pendingFocus, pending.id == id, Date() < pending.until { return }
            border.hide()
            return
        }
        border.show(
            around: frame, above: id, width: config.borderWidth,
            color: actionModeOn ? config.borderModeColor : config.borderColor,
            animation: config.focusAnimation, monitor: state.focusedMonitor
        )
    }

    // MARK: Focus

    /// Accessibility reports the real process ID of apps that NSWorkspace
    /// lists as -1, such as an app bundle started from its bare executable.
    private func frontmostPID() -> pid_t? {
        if let pid = AXUIElementCreateSystemWide().element(kAXFocusedApplicationAttribute)?.pid {
            return pid
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func systemFocusedWindow() -> WindowID? {
        guard let pid = frontmostPID(),
              let app = apps[pid]
        else { return nil }
        return app.element.element(kAXFocusedWindowAttribute)?.windowID
    }

    /// Raises a window, or takes focus away from parked windows when the
    /// workspace is empty.
    private func focusSystem(on id: WindowID?) {
        pendingFocus = (id, Date().addingTimeInterval(Self.focusSettleTime))
        guard let id, let window = windows[id], let app = apps[window.pid] else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        app.element.set(kAXFrontmostAttribute, kCFBooleanTrue)
        window.element.set(kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    /// Follows focus changes that macOS reports, such as clicks and Command-Tab.
    private func syncFocus() {
        guard isEnabled else { return }
        guard let pid = frontmostPID(),
              let element = apps[pid]?.element.element(kAXFocusedWindowAttribute),
              let id = element.windowID
        else {
            updateBorder()
            return
        }
        if let pending = pendingFocus, Date() < pending.until, pending.id != id {
            return
        }
        pendingFocus = nil
        if windows[id] == nil {
            _ = adopt(element, pid: pid, add: true)
        }
        guard state.contains(id) else {
            updateBorder()
            return
        }
        // Focus acknowledgments arrive after keyboard commands. Preserve the
        // active transition when macOS reports the window we already selected.
        guard state.focusedWindow != id else {
            updateBorder()
            return
        }
        state.focus(id)
        apply(focus: false, animation: config.focusAnimation)
    }

    // MARK: Apps and windows

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (NSRunningApplication?) -> Void) {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { handler(app) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.track(app)
            // Windows can appear before the observer is ready.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self.scan(app.processIdentifier) }
            }
        }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            self.untrack(app.processIdentifier)
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            for (id, window) in self.windows where window.pid == app.processIdentifier {
                self.suspend(id)
            }
            self.apply(focus: false)
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] app in
            guard let self, let app else { return }
            for (id, window) in self.windows where window.pid == app.processIdentifier {
                self.resume(id)
            }
            self.apply(focus: false)
        }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] _ in
            self?.syncFocus()
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            for pid in self.apps.keys {
                self.scan(pid)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.setMonitors(Screens.monitors())
                self.apply(focus: false)
            }
        }
    }

    private func track(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else {
            return
        }
        track(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    /// Tracks apps that own normal windows but that NSWorkspace reports with
    /// process ID -1, such as an app started from its bare executable. Such an
    /// app sends no launch or quit notification, so this runs every second.
    /// Returns the newly tracked process IDs.
    @discardableResult
    private func trackUnlistedApps() -> [pid_t] {
        var added: [pid_t] = []
        for pid in WindowList.ownerPIDs() where apps[pid] == nil {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }
            track(pid: pid, bundleID: app.bundleIdentifier, name: app.localizedName)
            if apps[pid] != nil {
                added.append(pid)
            }
        }
        // Without a quit notification, notice exits here.
        for pid in apps.keys where kill(pid, 0) != 0 && errno == ESRCH {
            untrack(pid)
        }
        return added
    }

    private func track(pid: pid_t, bundleID: String?, name: String?) {
        guard pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              apps[pid] == nil
        else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &created) == .success, let observer = created else {
            return
        }
        let element = AXUIElementCreateApplication(pid)
        for name in Self.appNotifications {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        apps[pid] = TrackedApp(
            element: element,
            observer: observer,
            bundleID: bundleID,
            name: name
        )
    }

    private func untrack(_ pid: pid_t) {
        for (id, window) in windows where window.pid == pid {
            windows[id] = nil
            state.removeWindow(id)
        }
        if let app = apps.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(app.observer), .defaultMode)
        }
        apply(focus: true)
    }

    private func scan(_ pid: pid_t) {
        var changed = false
        for element in apps[pid]?.element.windows ?? [] {
            changed = adopt(element, pid: pid, add: true) != nil || changed
        }
        if changed {
            apply(focus: false)
        }
    }

    /// Starts tracking a standard window. With `add`, it also joins the layout.
    private func adopt(_ element: AXUIElement, pid: pid_t, add: Bool) -> WindowID? {
        guard let id = element.windowID,
              windows[id] == nil,
              element.string(kAXRoleAttribute) == kAXWindowRole,
              element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              !element.bool("AXFullScreen"),
              let app = apps[pid]
        else { return nil }
        for name in Self.windowNotifications {
            AXObserverAddNotification(app.observer, element, name as CFString, refcon)
        }
        windows[id] = TrackedWindow(element: element, pid: pid)
        if element.bool(kAXMinimizedAttribute) {
            windows[id]?.suspendedWorkspace = ""
        } else if add {
            addToState(id, atEnd: false)
        }
        return id
    }

    private func addToState(_ id: WindowID, atEnd: Bool, workspace: String? = nil) {
        guard let window = windows[id] else {
            return
        }
        let rule = config.rule(for: apps[window.pid]?.bundleID)
        let fixedSize = !window.element.isSettable(kAXSizeAttribute)
            || !window.element.isSettable(kAXPositionAttribute)
        let center = window.element.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        let monitor = center.flatMap { point in
            state.monitors.first { $0.frame.contains(point) }?.id
        }
        state.addWindow(
            id,
            floating: rule?.float == true || fixedSize,
            workspace: workspace ?? rule?.workspace,
            monitor: monitor,
            atEnd: atEnd
        )
    }

    private func suspend(_ id: WindowID) {
        guard let name = state.workspaceName(of: id) else {
            return
        }
        windows[id]?.suspendedWorkspace = name
        windows[id]?.parked = false
        state.removeWindow(id)
    }

    private func resume(_ id: WindowID) {
        guard let name = windows[id]?.suspendedWorkspace else {
            return
        }
        windows[id]?.suspendedWorkspace = nil
        addToState(id, atEnd: false, workspace: name.isEmpty ? nil : name)
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            guard let pid = element.pid else {
                return
            }
            if adopt(element, pid: pid, add: true) != nil {
                apply(focus: false)
                syncFocus()
            } else {
                // Some apps set the subrole after creating the window.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated { self.scan(pid) }
                }
            }
        case kAXFocusedWindowChangedNotification:
            syncFocus()
        case kAXUIElementDestroyedNotification:
            guard let id = trackedID(of: element) else {
                return
            }
            windows[id] = nil
            state.removeWindow(id)
            apply(focus: true)
        case kAXWindowMiniaturizedNotification:
            guard let id = trackedID(of: element) else {
                return
            }
            suspend(id)
            apply(focus: true)
        case kAXWindowDeminiaturizedNotification:
            guard let id = trackedID(of: element) else {
                return
            }
            resume(id)
            state.focus(id)
            apply(focus: true)
        case kAXMovedNotification, kAXResizedNotification:
            if let id = trackedID(of: element), id == state.focusedWindow, animations[id] == nil {
                updateBorder()
            }
        default:
            break
        }
    }

    private func trackedID(of element: AXUIElement) -> WindowID? {
        windows.first { CFEqual($0.value.element, element) }?.key
    }

    private var refcon: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else {
        return
    }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handle(notification as String, element: element)
    }
}

extension AXUIElement {
    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }
}

/// Reads the window server's on-screen window list.
enum WindowList {
    /// Process IDs of apps with on-screen windows in the managed layer.
    static func ownerPIDs() -> Set<pid_t> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return Set(list.compactMap { info in
            (info[kCGWindowLayer as String] as? Int) == 0
                ? info[kCGWindowOwnerPID as String] as? pid_t
                : nil
        })
    }
}

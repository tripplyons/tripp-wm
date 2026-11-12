import AppKit
import ApplicationServices
import TrippWMCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configURL = Config.defaultURL
    private var config = Config()
    private var configStamp: Date?
    private var problems: [String] = []
    /// A missing permission, kept apart from configuration problems so that a
    /// reload does not clear it.
    private var permissionProblem: String?

    private var manager: WindowManager?
    private let hotKeys = HotKeys()
    private let eventTap = EventTap()
    private let pointerGrid = PointerGrid()
    private let actionMode = ActionModeTap()
    private let screenWarmth = ScreenWarmth()
    private var server: ControlServer?
    private var timers: [Timer] = []
    private var signalSources: [DispatchSourceSignal] = []

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let problemItem = NSMenuItem()
    private let toggleItem = NSMenuItem()
    private var isEnabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            server = try ControlServer { [weak self] request in
                self?.respond(to: request) ?? "error: shutting down"
            }
        } catch {
            log("\(error)")
            // A second copy has nothing to do; exit cleanly so launchd stops.
            exit(0)
        }
        setUpStatusItem()
        handleSignals()
        screenWarmth.start()
        reloadConfig()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            start()
            return
        }
        problems = ["Waiting for Accessibility permission"]
        updateStatus()
        schedule(every: 1) { [weak self] timer in
            guard AXIsProcessTrusted() else {
                return
            }
            timer.invalidate()
            self?.problems = []
            self?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDown()
    }

    // MARK: Startup

    private func start() {
        let manager = WindowManager(config: config)
        manager.onChange = { [weak self] in self?.updateStatus() }
        self.manager = manager
        manager.start()

        hotKeys.onCommand = { [weak self] command in self?.perform(command) }
        eventTap.onMouseUp = { [weak manager] in manager?.mouseReleased() }
        actionMode.onCommand = { [weak self] command in self?.perform(command) }
        actionMode.onModeChange = { [weak self] isOn in
            self?.manager?.setActionMode(isOn)
            self?.registerHotKeys()
        }
        startActionMode()
        apply(config)
        startEventTap()
        server?.start()

        // chezmoi replaces the file, so poll its modification date.
        schedule(every: 1) { [weak self] _ in
            guard let self, self.modificationDate() != self.configStamp else {
                return
            }
            self.reloadConfig()
        }
    }

    /// Listen-only taps need Input Monitoring. Without it macOS still creates
    /// the tap but delivers no events, so create it only after the grant.
    private func startEventTap() {
        if CGPreflightListenEventAccess() {
            createEventTap()
            return
        }
        // Adds tripp-wm to the Input Monitoring list and asks once.
        CGRequestListenEventAccess()
        permissionProblem = "Waiting for Input Monitoring permission"
        log("waiting for Input Monitoring permission; manual resize detection is off")
        updateStatus()
        schedule(every: 1) { [weak self] timer in
            guard CGPreflightListenEventAccess() else {
                return
            }
            timer.invalidate()
            self?.permissionProblem = nil
            self?.createEventTap()
            self?.updateStatus()
        }
    }

    private func createEventTap() {
        if eventTap.start() {
            log("listening for mouse releases")
        } else {
            log("cannot create the event tap; manual resize detection is off")
        }
    }

    /// macOS refuses keyboard taps until tripp-wm has Input Monitoring, so
    /// keep trying until the grant arrives.
    private func startActionMode() {
        var started = actionMode.start()
        if !started {
            log("cannot read keys yet; the right Option action mode starts once Input Monitoring is granted")
        }
        // Retries until the grant arrives, then repairs taps that macOS
        // turned off.
        schedule(every: 1) { [weak self] _ in
            guard let self, self.actionMode.start() else {
                return
            }
            if !started {
                started = true
                self.log("reading keys for the right Option action mode")
            }
            self.actionMode.ensureRunning()
        }
    }

    private func handleSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.shutDown() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func shutDown() {
        screenWarmth.stop()
        manager?.restoreWindows()
        server?.stop()
    }

    // MARK: Commands

    private func perform(_ command: Command) {
        guard isEnabled || command == .reloadConfig else { return }
        switch command {
        case .reloadConfig:
            reloadConfig()
        case .grid:
            // The grid reads keys through its own tap.
            actionMode.exit()
            pointerGrid.toggle()
        case let .exec(shellCommand):
            actionMode.exit()
            Launcher.run(shellCommand)
        default:
            manager?.perform(command)
        }
    }

    private func respond(to request: IPC.Request) -> String {
        guard let manager else {
            return "error: waiting for Accessibility permission"
        }
        switch request {
        case .queryState:
            return manager.snapshot().json()
        case let .command(command):
            guard isEnabled || command == .reloadConfig else {
                return "error: tripp-wm is disabled"
            }
            perform(command)
            if command == .reloadConfig, let problem = problems.first {
                return "error: \(problem)"
            }
            return "ok"
        }
    }

    // MARK: Configuration

    private func reloadConfig() {
        configStamp = modificationDate()
        do {
            apply(try Config.load(from: configURL))
            log("loaded \(configURL.path)")
        } catch {
            // Keep the last good configuration.
            problems = ["\(error)"]
            log("\(error)")
        }
        updateStatus()
    }

    private func apply(_ config: Config) {
        self.config = config
        problems = []
        manager?.update(config: config)
        pointerGrid.colors = .init(background: config.gridBackground, text: config.gridText, accent: config.gridAccent)
        pointerGrid.toggleKeys = Set(config.bindings.filter { $0.value == .grid }.keys)
        actionMode.mode.bindings = config.bindings
        registerHotKeys()
    }

    /// The action mode reads every key itself, so hot keys step aside while
    /// it is on; otherwise an Option chord would run its command twice.
    private func registerHotKeys() {
        guard manager != nil else {
            return
        }
        let active = isEnabled && !actionMode.mode.isOn
        let taken = hotKeys.register(active ? config.bindings : [:])
        let prefix = "Keys used by another app: "
        problems.removeAll { $0.hasPrefix(prefix) }
        if !taken.isEmpty {
            let keys = taken.map(\.description).sorted().joined(separator: ", ")
            problems.insert(prefix + keys, at: 0)
            log(problems[0])
        }
        updateStatus()
    }

    private func modificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let menu = NSMenu()
        problemItem.isEnabled = false
        menu.addItem(problemItem)
        toggleItem.target = self
        toggleItem.action = #selector(toggleEnabled)
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(screenWarmth.menuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadFromMenu), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open Config", action: #selector(openConfig), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit tripp-wm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateStatus()
    }

    /// Shows occupied workspaces with the focused one in brackets.
    private func updateStatus() {
        toggleItem.title = isEnabled ? "Disable tripp-wm" : "Enable tripp-wm"
        toggleItem.isEnabled = manager != nil
        let problem = permissionProblem ?? problems.first
        problemItem.title = problem ?? ""
        problemItem.isHidden = problem == nil
        guard isEnabled else {
            statusItem.button?.title = "tripp-wm (disabled)" + (problem == nil ? "" : " !")
            return
        }
        guard let state = manager?.state else {
            statusItem.button?.title = "tripp-wm !"
            return
        }
        let focused = state.focusedWorkspaceName
        let names = state.workspaces
            .filter { !$0.isEmpty || $0.name == focused }
            .map { $0.name == focused ? "[\($0.name)]" : $0.name }
        statusItem.button?.title = names.joined(separator: " ") + (problem == nil ? "" : " !")
    }

    @objc private func toggleEnabled() {
        guard let manager else { return }
        isEnabled.toggle()
        actionMode.isAllowed = isEnabled
        if !isEnabled {
            pointerGrid.dismiss()
            actionMode.exit()
        }
        manager.setEnabled(isEnabled)
        apply(config)
        // Re-enabling rescans every window on the main thread, which can stall
        // long enough for macOS to turn the keyboard taps off.
        actionMode.reset()
        updateStatus()
    }

    @objc private func reloadFromMenu() {
        reloadConfig()
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(configURL)
    }

    // MARK: Helpers

    private func schedule(every interval: TimeInterval, _ body: @escaping @MainActor (Timer) -> Void) {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated { body(timer) }
        }
        timers.append(timer)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("tripp-wm: \(message)\n".utf8))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

import Foundation

/// Runs `exec` commands through `/bin/sh`.
@MainActor
enum Launcher {
    /// launchd gives agents only the system paths.
    private static let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
    private static var exitSources: [pid_t: DispatchSourceProcess] = [:]

    static func run(_ shellCommand: String) {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session keeps the program running when launchd stops
        // tripp-wm, which kills the rest of the agent's process group.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)

        var environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = (extraPaths.filter { !paths.contains($0) } + paths).joined(separator: ":")

        let arguments = ["/bin/sh", "-c", shellCommand]
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let status = withCStrings(arguments) { argv in
            withCStrings(environmentStrings) { envp in
                posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
            }
        }
        guard status == 0 else {
            let reason = String(cString: strerror(status))
            FileHandle.standardError.write(Data("tripp-wm: cannot run \"\(shellCommand)\": \(reason)\n".utf8))
            return
        }
        reap(pid)
    }

    /// Collects the shell's exit status so it does not linger as a zombie.
    private static func reap(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            MainActor.assumeIsolated {
                exitSources.removeValue(forKey: pid)?.cancel()
            }
        }
        exitSources[pid] = source
        source.resume()
    }

    private static func withCStrings<Result>(
        _ strings: [String],
        _ body: ([UnsafeMutablePointer<CChar>?]) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}

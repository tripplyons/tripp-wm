import Foundation

/// The control socket protocol: the client writes one request line and the
/// server answers with one line, `ok`, `error: <reason>`, or JSON for queries.
public enum IPC {
    public enum Request: Equatable, Sendable {
        case queryState
        case command(Command)

        public init(parsing line: String) throws {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "query state" {
                self = .queryState
            } else {
                self = .command(try Command(parsing: trimmed))
            }
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// A per-user socket in the Darwin user temporary directory.
    public static var socketPath: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        // The length counts the terminating null.
        let directory = length > 1
            ? String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : NSTemporaryDirectory()
        return (directory as NSString).appendingPathComponent("tripp-wm.sock")
    }

    /// Sends one request and returns the response line.
    public static func send(_ request: String, to path: String = socketPath) throws -> String {
        let socket = try connect(to: path)
        defer { close(socket) }
        let data = Array((request + "\n").utf8)
        var written = 0
        while written < data.count {
            let result = data[written...].withUnsafeBytes {
                write(socket, $0.baseAddress, $0.count)
            }
            guard result > 0 else {
                throw Failure(description: "cannot write to \(path): \(String(cString: strerror(errno)))")
            }
            written += result
        }
        shutdown(socket, SHUT_WR)
        var response = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(socket, &buffer, buffer.count)
            guard count > 0 else {
                break
            }
            response += buffer[..<count]
        }
        return String(decoding: response, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    /// Binds a listening socket, replacing a stale socket file. Fails when
    /// another server answers on the path.
    public static func listen(at path: String = socketPath) throws -> Int32 {
        if let existing = try? connect(to: path) {
            close(existing)
            throw Failure(description: "another tripp-wm is running")
        }
        unlink(path)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw Failure(description: "cannot create socket: \(String(cString: strerror(errno)))")
        }
        var address = try makeAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(socket)
            throw Failure(description: "cannot listen on \(path): \(reason)")
        }
        chmod(path, 0o600)
        return socket
    }

    private static func connect(to path: String) throws -> Int32 {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw Failure(description: "cannot create socket: \(String(cString: strerror(errno)))")
        }
        var address = try makeAddress(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            throw Failure(description: "tripp-wm is not running (\(path))")
        }
        return socket
    }

    private static func makeAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw Failure(description: "socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}

/// The JSON answer to `query state`.
public struct Snapshot: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var id: WindowID
        public var app: String?
        public var title: String?

        public init(id: WindowID, app: String?, title: String?) {
            self.id = id
            self.app = app
            self.title = title
        }
    }

    public struct Workspace: Codable, Equatable, Sendable {
        public var name: String
        /// Display ID of the monitor that shows it, or nil when hidden.
        public var monitor: MonitorID?
        public var columns: [[Window]]
        public var floating: [Window]
    }

    public var focusedWorkspace: String?
    public var focusedWindow: WindowID?
    public var workspaces: [Workspace]

    enum CodingKeys: String, CodingKey {
        case focusedWorkspace = "focused-workspace"
        case focusedWindow = "focused-window"
        case workspaces
    }

    public init(state: WMState, describe: (WindowID) -> Window) {
        focusedWorkspace = state.focusedWorkspaceName
        focusedWindow = state.focusedWindow
        workspaces = state.workspaces.map { workspace in
            Workspace(
                name: workspace.name,
                monitor: state.monitor(showing: workspace.name),
                columns: workspace.columns.map { $0.windows.map(describe) },
                floating: workspace.floating.map(describe)
            )
        }
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

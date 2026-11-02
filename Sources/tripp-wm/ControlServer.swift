import Foundation
import TrippWMCore

/// Serves `tripp-wmctl` on the control socket. Connections are read on a
/// background thread and answered on the main thread.
final class ControlServer: @unchecked Sendable {
    private let socket: Int32
    private let respond: @MainActor (IPC.Request) -> String

    init(respond: @escaping @MainActor (IPC.Request) -> String) throws {
        socket = try IPC.listen()
        self.respond = respond
    }

    func start() {
        let thread = Thread { [self] in
            while true {
                let client = accept(socket, nil, nil)
                guard client >= 0 else {
                    continue
                }
                serve(client)
                close(client)
            }
        }
        thread.name = "tripp-wm control"
        thread.start()
    }

    func stop() {
        unlink(IPC.socketPath)
    }

    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !request.contains(UInt8(ascii: "\n")), request.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else {
                break
            }
            request += buffer[..<count]
        }
        let line = String(decoding: request, as: UTF8.self)
        let response: String
        do {
            let parsed = try IPC.Request(parsing: line)
            response = DispatchQueue.main.sync {
                MainActor.assumeIsolated { respond(parsed) }
            }
        } catch {
            response = "error: \(error)"
        }
        let data = Array((response + "\n").utf8)
        var written = 0
        while written < data.count {
            let count = data[written...].withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            guard count > 0 else {
                return
            }
            written += count
        }
    }
}

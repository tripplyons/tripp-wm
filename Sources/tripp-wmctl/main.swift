import Foundation
import TrippWMCore

let usage = """
usage: tripp-wmctl <command>
       tripp-wmctl query state

Commands:
  focus left|right|up|down
  move left|right|up|down
  consume-or-expel left|right
  cycle-width | maximize-column | center-column | toggle-float
  workspace <name>|next|prev|back-and-forth
  move-to-workspace <name>
  grid
  exec <shell command>
  reload-config
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments == ["-h"] || arguments == ["--help"] {
    print(usage)
    exit(arguments.isEmpty ? 2 : 0)
}

let request = arguments.joined(separator: " ")
do {
    // Check the request here so typos fail without a running window manager.
    _ = try IPC.Request(parsing: request)
    let response = try IPC.send(request)
    if response.hasPrefix("error: ") {
        FileHandle.standardError.write(Data((response + "\n").utf8))
        exit(1)
    }
    if response != "ok" {
        print(response)
    }
} catch {
    FileHandle.standardError.write(Data("tripp-wmctl: \(error)\n".utf8))
    exit(1)
}

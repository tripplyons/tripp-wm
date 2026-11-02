import Foundation

/// An action that a key binding or `tripp-wmctl` can run.
public enum Command: Equatable, Sendable {
    case focus(Direction)
    case move(Direction)
    /// Push the focused window out of its column, or pull it into the
    /// neighboring column when it is alone.
    case consumeOrExpel(Direction)
    case cycleWidth
    case maximizeColumn
    case centerColumn
    case toggleFloat
    case workspace(String)
    case workspaceNext
    case workspacePrevious
    case workspaceBackAndForth
    case moveToWorkspace(String)
    case reloadConfig
    /// Open or close the pointer grid.
    case grid
    /// Run a shell command, such as `exec open -na Ghostty.app`.
    case exec(String)

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Parses commands such as `focus left`, `workspace 3`, and `cycle-width`.
    public init(parsing text: String) throws {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = words.first else {
            throw ParseError(description: "empty command")
        }
        if name == "exec" {
            // Keep the shell command's own spacing and quotes.
            let start = text.range(of: name)!.upperBound
            let shellCommand = text[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shellCommand.isEmpty else {
                throw ParseError(description: "exec needs a shell command")
            }
            self = .exec(shellCommand)
            return
        }
        let arguments = Array(words.dropFirst())

        func direction(_ allowed: [Direction] = Direction.allCases) throws -> Direction {
            guard arguments.count == 1,
                  let direction = Direction(rawValue: arguments[0]),
                  allowed.contains(direction)
            else {
                let names = allowed.map(\.rawValue).joined(separator: ", ")
                throw ParseError(description: "\(name) needs one of: \(names)")
            }
            return direction
        }

        func noArguments(_ command: Command) throws -> Command {
            guard arguments.isEmpty else {
                throw ParseError(description: "\(name) takes no arguments")
            }
            return command
        }

        func workspaceName() throws -> String {
            guard arguments.count == 1 else {
                throw ParseError(description: "\(name) needs a workspace name")
            }
            return arguments[0]
        }

        switch name {
        case "focus":
            self = .focus(try direction())
        case "move":
            self = .move(try direction())
        case "consume-or-expel":
            self = .consumeOrExpel(try direction([.left, .right]))
        case "cycle-width":
            self = try noArguments(.cycleWidth)
        case "maximize-column":
            self = try noArguments(.maximizeColumn)
        case "center-column":
            self = try noArguments(.centerColumn)
        case "toggle-float":
            self = try noArguments(.toggleFloat)
        case "workspace":
            switch try workspaceName() {
            case "next": self = .workspaceNext
            case "prev": self = .workspacePrevious
            case "back-and-forth": self = .workspaceBackAndForth
            case let workspace: self = .workspace(workspace)
            }
        case "move-to-workspace":
            self = .moveToWorkspace(try workspaceName())
        case "reload-config":
            self = try noArguments(.reloadConfig)
        case "grid":
            self = try noArguments(.grid)
        default:
            throw ParseError(description: "unknown command: \(name)")
        }
    }
}

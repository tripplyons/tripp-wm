import Foundation
import TOMLDecoder

public struct RGBA: Equatable, Sendable {
    public var red, green, blue, alpha: Double

    /// Parses `#rrggbb` or `#rrggbbaa`.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") {
            digits = digits.dropFirst()
        }
        guard digits.count == 6 || digits.count == 8,
              let value = UInt32(digits, radix: 16)
        else { return nil }
        let full = digits.count == 6 ? value << 8 | 0xFF : value
        red = Double(full >> 24 & 0xFF) / 255
        green = Double(full >> 16 & 0xFF) / 255
        blue = Double(full >> 8 & 0xFF) / 255
        alpha = Double(full & 0xFF) / 255
    }
}

/// Floats a window or sends it to a workspace when its app opens it.
public struct WindowRule: Equatable, Sendable {
    /// Bundle identifier of the app.
    public var appID: String
    public var float: Bool
    public var workspace: String?
}

public struct Config: Equatable, Sendable {
    public static let workspaceNames = (1...9).map(String.init)

    public var layout = LayoutSettings()
    public var focusAnimation = AnimationSettings()
    public var moveAnimation = AnimationSettings()
    public var border = true
    public var borderWidth = 2.0
    public var borderColor = RGBA(hex: "#f4cb7e")!
    public var gridBackground = RGBA(hex: "#000000b3")!
    public var gridText = RGBA(hex: "#ffedd7")!
    public var gridAccent = RGBA(hex: "#f4cb7e")!
    public var bindings: [KeyCombo: Command] = Config.defaultBindings
    public var rules: [WindowRule] = []

    public struct LoadError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public init() {}

    public static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("tripp-wm/config.toml")
    }

    /// Reads a config file. A missing file gives the defaults.
    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Config()
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LoadError(description: "cannot read \(url.path): \(error.localizedDescription)")
        }
        return try Config(parsing: text)
    }

    /// Parses TOML. A `[bindings]` table replaces every default binding.
    public init(parsing text: String) throws {
        let file: File
        do {
            file = try TOMLDecoder().decode(File.self, from: text)
        } catch {
            throw LoadError(description: "invalid config: \(error)")
        }

        if let gaps = file.gaps {
            guard gaps >= 0 else {
                throw LoadError(description: "gaps must not be negative")
            }
            layout.gaps = gaps
        }
        if let widths = file.columnWidths {
            guard !widths.isEmpty, widths.allSatisfy({ $0 > 0 && $0 <= 1 }) else {
                throw LoadError(description: "column-widths must be fractions in (0, 1]")
            }
            layout.columnWidths = widths
        }
        if let width = file.defaultColumnWidth {
            guard width > 0, width <= 1 else {
                throw LoadError(description: "default-column-width must be a fraction in (0, 1]")
            }
            layout.defaultColumnWidth = width
        }
        focusAnimation = try Self.animation(file.animations?.focus, name: "animations.focus")
        moveAnimation = try Self.animation(file.animations?.move, name: "animations.move")
        if let section = file.border {
            border = section.enabled ?? border
            if let width = section.width {
                guard width > 0 else {
                    throw LoadError(description: "border.width must be positive")
                }
                borderWidth = width
            }
            borderColor = try Self.color(section.color, name: "border.color") ?? borderColor
        }
        if let section = file.grid {
            gridBackground = try Self.color(section.background, name: "grid.background") ?? gridBackground
            gridText = try Self.color(section.text, name: "grid.text") ?? gridText
            gridAccent = try Self.color(section.accent, name: "grid.accent") ?? gridAccent
        }
        if let table = file.bindings {
            bindings = [:]
            for (key, text) in table.sorted(by: { $0.key < $1.key }) {
                let combo: KeyCombo
                let command: Command
                do {
                    combo = try KeyCombo(parsing: key)
                    command = try Command(parsing: text)
                } catch {
                    throw LoadError(description: "binding \"\(key)\": \(error)")
                }
                if let existing = bindings.keys.first(where: { $0 == combo }) {
                    throw LoadError(description: "\"\(key)\" and \"\(existing)\" are the same key")
                }
                bindings[combo] = command
            }
        }
        rules = try (file.rules ?? []).map { rule in
            guard !rule.appID.isEmpty else {
                throw LoadError(description: "rules need an app-id")
            }
            if let workspace = rule.workspace, !Self.workspaceNames.contains(workspace) {
                throw LoadError(description: "rule for \(rule.appID): no workspace named \"\(workspace)\"")
            }
            return WindowRule(appID: rule.appID, float: rule.float ?? false, workspace: rule.workspace)
        }
    }

    private static func animation(_ section: AnimationSection?, name: String) throws -> AnimationSettings {
        var settings = AnimationSettings()
        if let duration = section?.duration {
            guard duration.isFinite, duration >= 0 else {
                throw LoadError(description: "\(name).duration must be finite and nonnegative")
            }
            settings.duration = duration
        }
        settings.easing = section?.easing ?? settings.easing
        return settings
    }

    private static func color(_ hex: String?, name: String) throws -> RGBA? {
        guard let hex else {
            return nil
        }
        guard let color = RGBA(hex: hex) else {
            throw LoadError(description: "\(name) must be #rrggbb or #rrggbbaa")
        }
        return color
    }

    /// The first rule for an app.
    public func rule(for appID: String?) -> WindowRule? {
        appID.flatMap { id in rules.first { $0.appID == id } }
    }

    public static let defaultBindings: [KeyCombo: Command] = {
        var bindings: [String: String] = [
            "alt-[": "consume-or-expel left",
            "alt-]": "consume-or-expel right",
            "alt-r": "cycle-width",
            "alt-f": "maximize-column",
            "alt-c": "center-column",
            "alt-shift-f": "toggle-float",
            "alt-space": "grid",
            "alt-t": "exec open -na Ghostty.app",
            "alt-shift-r": "reload-config",
            "alt-tab": "workspace back-and-forth",
            "alt-f17": "workspace-cycle 1 2",
            "alt-u": "workspace next",
            "alt-i": "workspace prev",
        ]
        for (key, direction) in [("h", "left"), ("j", "down"), ("k", "up"), ("l", "right")] {
            bindings["alt-\(key)"] = "focus \(direction)"
            bindings["alt-shift-\(key)"] = "move \(direction)"
        }
        for name in workspaceNames {
            bindings["alt-\(name)"] = "workspace \(name)"
            bindings["alt-shift-\(name)"] = "move-to-workspace \(name)"
        }
        var parsed: [KeyCombo: Command] = [:]
        for (key, command) in bindings {
            parsed[try! KeyCombo(parsing: key)] = try! Command(parsing: command)
        }
        return parsed
    }()

    private struct File: Decodable {
        var gaps: Double?
        var columnWidths: [Double]?
        var defaultColumnWidth: Double?
        var animations: AnimationsSection?
        var border: BorderSection?
        var grid: GridSection?
        var bindings: [String: String]?
        var rules: [RuleSection]?

        enum CodingKeys: String, CodingKey {
            case gaps
            case columnWidths = "column-widths"
            case defaultColumnWidth = "default-column-width"
            case animations, border, grid, bindings, rules
        }
    }

    private struct AnimationsSection: Decodable {
        var focus: AnimationSection?
        var move: AnimationSection?
    }

    private struct AnimationSection: Decodable {
        var duration: Double?
        var easing: AnimationEasing?
    }

    private struct BorderSection: Decodable {
        var enabled: Bool?
        var width: Double?
        var color: String?
    }

    private struct GridSection: Decodable {
        var background: String?
        var text: String?
        var accent: String?
    }

    private struct RuleSection: Decodable {
        var appID: String
        var float: Bool?
        var workspace: String?

        enum CodingKeys: String, CodingKey {
            case appID = "app-id"
            case float, workspace
        }
    }
}

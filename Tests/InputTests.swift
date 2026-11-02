import CoreGraphics
import Foundation
import Testing
import TrippWMCore

struct CommandTests {
    @Test
    func parsesCommandsWithArguments() throws {
        #expect(try Command(parsing: "focus left") == .focus(.left))
        #expect(try Command(parsing: "  move   down ") == .move(.down))
        #expect(try Command(parsing: "workspace back-and-forth") == .workspaceBackAndForth)
        #expect(try Command(parsing: "move-to-workspace 3") == .moveToWorkspace("3"))
        #expect(try IPC.Request(parsing: "query state\n") == .queryState)
        #expect(try Command(parsing: "grid") == .grid)
        #expect(try Command(parsing: "exec  open -a 'App Store'") == .exec("open -a 'App Store'"))
    }

    @Test
    func rejectsBadCommands() {
        #expect(throws: Command.ParseError.self) { try Command(parsing: "focus") }
        #expect(throws: Command.ParseError.self) { try Command(parsing: "consume-or-expel up") }
        #expect(throws: Command.ParseError.self) { try Command(parsing: "cycle-width now") }
        #expect(throws: Command.ParseError.self) { try Command(parsing: "explode") }
        #expect(throws: Command.ParseError.self) { try Command(parsing: "exec  ") }
    }
}

struct KeyComboTests {
    @Test
    func modifierOrderDoesNotMatter() throws {
        #expect(try KeyCombo(parsing: "alt-shift-h") == KeyCombo(parsing: "Shift-Option-H"))
        #expect(try KeyCombo(parsing: "alt-h") != KeyCombo(parsing: "alt-shift-h"))
    }

    @Test
    func trailingDashNamesTheMinusKey() throws {
        #expect(try KeyCombo(parsing: "alt--") == KeyCombo(parsing: "alt-minus"))
    }

    @Test
    func rejectsUnknownKeysAndBareKeys() {
        #expect(throws: KeyCombo.ParseError.self) { try KeyCombo(parsing: "alt-hyper") }
        #expect(throws: KeyCombo.ParseError.self) { try KeyCombo(parsing: "super-h") }
        #expect(throws: KeyCombo.ParseError.self) { try KeyCombo(parsing: "h") }
    }
}

struct ConfigTests {
    @Test
    func readsSettingsBindingsAndRules() throws {
        let config = try Config(parsing: """
        gaps = 4
        column-widths = [0.5, 1.0]

        [border]
        color = "#88a0bf"

        [grid]
        accent = "#88a0bf"

        [bindings]
        "alt-h" = "focus left"

        [[rules]]
        app-id = "com.apple.calculator"
        float = true

        [[rules]]
        app-id = "com.spotify.client"
        workspace = "9"
        """)
        #expect(config.layout.gaps == 4)
        #expect(config.layout.columnWidths == [0.5, 1])
        #expect(config.borderColor == RGBA(hex: "#88a0bfff"))
        #expect(config.gridAccent == RGBA(hex: "#88a0bf"))
        #expect(config.gridText == Config().gridText)
        #expect(config.bindings == [try KeyCombo(parsing: "alt-h"): .focus(.left)])
        #expect(config.rule(for: "com.apple.calculator")?.float == true)
        #expect(config.rule(for: "com.spotify.client")?.workspace == "9")
        #expect(config.rule(for: "com.example") == nil)
    }

    @Test
    func emptyConfigUsesDefaultBindings() throws {
        let config = try Config(parsing: "")
        #expect(config.bindings[try KeyCombo(parsing: "alt-shift-l")] == .move(.right))
        #expect(config.bindings[try KeyCombo(parsing: "alt-9")] == .workspace("9"))
    }

    @Test
    func reportsInvalidValues() {
        #expect(throws: Config.LoadError.self) { try Config(parsing: "column-widths = [1.5]") }
        #expect(throws: Config.LoadError.self) { try Config(parsing: "[bindings]\n\"alt-h\" = \"fly\"") }
        #expect(throws: Config.LoadError.self) {
            try Config(parsing: "[bindings]\n\"alt-h\" = \"focus left\"\n\"option-h\" = \"focus right\"")
        }
        #expect(throws: Config.LoadError.self) {
            try Config(parsing: "[[rules]]\napp-id = \"a\"\nworkspace = \"10\"")
        }
        #expect(throws: Config.LoadError.self) { try Config(parsing: "gaps = ") }
    }

    /// The test runner renders the chezmoi-managed config and passes its path.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIPP_WM_CONFIG"] != nil))
    func managedConfigLoads() throws {
        let path = ProcessInfo.processInfo.environment["TRIPP_WM_CONFIG"]!
        let config = try Config.load(from: URL(fileURLWithPath: path))
        #expect(config.bindings == Config.defaultBindings)
    }
}

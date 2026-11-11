import Testing
import TrippWMCore

struct ActionModeTests {
    private static let rightOption = ActionMode.rightOptionKeyCode
    private static let leftOption: UInt32 = 0x3A
    private static let h: UInt32 = 0x04
    private static let n: UInt32 = 0x2D
    private static let i: UInt32 = 0x22
    private static let q: UInt32 = 0x0C
    private static let space: UInt32 = 0x31
    private static let escape: UInt32 = 0x35

    private func modeOn() -> ActionMode {
        var mode = ActionMode(bindings: Config.defaultBindings)
        _ = mode.modifierChanged(keyCode: Self.rightOption, rightOptionDown: true)
        _ = mode.modifierChanged(keyCode: Self.rightOption, rightOptionDown: false)
        return mode
    }

    @Test
    func loneRightOptionTogglesTheMode() {
        var mode = modeOn()
        #expect(mode.isOn)
        #expect(mode.modifierChanged(keyCode: Self.rightOption, rightOptionDown: true) == .pass)
        #expect(mode.modifierChanged(keyCode: Self.rightOption, rightOptionDown: false) == .pass)
        #expect(!mode.isOn)
    }

    @Test
    func rightOptionUsedAsModifierDoesNotToggle() {
        var mode = ActionMode(bindings: Config.defaultBindings)
        _ = mode.modifierChanged(keyCode: Self.rightOption, rightOptionDown: true)
        #expect(mode.keyDown(keyCode: Self.n, modifiers: .option, isRepeat: false) == .pass)
        #expect(mode.keyUp(keyCode: Self.n) == .pass)
        _ = mode.modifierChanged(keyCode: Self.rightOption, rightOptionDown: false)
        #expect(!mode.isOn)
    }

    @Test
    func leftOptionDoesNotToggle() {
        var mode = ActionMode(bindings: Config.defaultBindings)
        _ = mode.modifierChanged(keyCode: Self.leftOption, rightOptionDown: false)
        _ = mode.modifierChanged(keyCode: Self.leftOption, rightOptionDown: false)
        #expect(!mode.isOn)
    }

    @Test
    func keysRunTheirOptionBindings() {
        var mode = modeOn()
        #expect(mode.keyDown(keyCode: Self.h, modifiers: [], isRepeat: false) == .run(.focus(.left)))
        #expect(mode.keyUp(keyCode: Self.h) == .swallow)
        #expect(mode.keyDown(keyCode: Self.h, modifiers: .shift, isRepeat: false) == .run(.move(.left)))
        #expect(mode.keyDown(keyCode: Self.h, modifiers: .option, isRepeat: false) == .run(.focus(.left)))
        #expect(mode.keyDown(keyCode: Self.n, modifiers: [], isRepeat: false) == .run(.workspaceNext))
        #expect(mode.keyDown(keyCode: Self.h, modifiers: [], isRepeat: true) == .swallow)
        #expect(mode.isOn)
    }

    @Test
    func unboundKeysAreSwallowed() {
        var mode = modeOn()
        #expect(mode.keyDown(keyCode: Self.q, modifiers: [], isRepeat: false) == .swallow)
        #expect(mode.keyDown(keyCode: Self.q, modifiers: .command, isRepeat: false) == .swallow)
        #expect(mode.keyUp(keyCode: Self.q) == .swallow)
        #expect(mode.isOn)
    }

    @Test
    func escapeAndIExitAndTheirKeyUpsStayDropped() {
        for key in [Self.escape, Self.i] {
            var mode = modeOn()
            #expect(mode.keyDown(keyCode: key, modifiers: [], isRepeat: false) == .swallow)
            #expect(!mode.isOn)
            #expect(mode.needsKeys)
            #expect(mode.keyUp(keyCode: key) == .swallow)
            #expect(!mode.needsKeys)
            #expect(mode.keyDown(keyCode: key, modifiers: [], isRepeat: false) == .pass)
        }
    }

    @Test
    func gridAndExecLeaveTheMode() throws {
        var mode = modeOn()
        #expect(mode.keyDown(keyCode: Self.space, modifiers: [], isRepeat: false) == .run(.grid))
        #expect(!mode.isOn)
        #expect(mode.keyUp(keyCode: Self.space) == .swallow)

        mode = modeOn()
        mode.bindings[try KeyCombo(parsing: "alt-q")] = .exec("true")
        #expect(mode.keyDown(keyCode: Self.q, modifiers: [], isRepeat: false) == .run(.exec("true")))
        #expect(!mode.isOn)
    }

    @Test
    func keysPassWhenOff() {
        var mode = ActionMode(bindings: Config.defaultBindings)
        #expect(mode.keyDown(keyCode: Self.h, modifiers: [], isRepeat: false) == .pass)
        #expect(mode.keyUp(keyCode: Self.h) == .pass)
        #expect(!mode.needsKeys)
    }

    @Test
    func nAndPAreBoundAndUAndIAreNot() throws {
        let bindings = Config.defaultBindings
        #expect(bindings[try KeyCombo(parsing: "alt-n")] == .workspaceNext)
        #expect(bindings[try KeyCombo(parsing: "alt-p")] == .workspacePrevious)
        #expect(bindings[try KeyCombo(parsing: "alt-u")] == nil)
        #expect(bindings[try KeyCombo(parsing: "alt-i")] == nil)
    }
}

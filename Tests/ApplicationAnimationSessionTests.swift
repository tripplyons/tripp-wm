import Testing
import TrippWMCore

private final class FakeAnimationApp: ApplicationAnimationBackend {
    var enhanced = true
    var acceptsWrites = true
    var reads = 0
    var writes: [Bool] = []

    var enhancedUserInterface: Bool {
        reads += 1
        return enhanced
    }

    func setEnhancedUserInterface(_ enabled: Bool) -> Bool {
        writes.append(enabled)
        guard acceptsWrites else { return false }
        enhanced = enabled
        return true
    }
}

struct ApplicationAnimationSessionTests {
    @Test func keepsNativeAnimationDisabledUntilCompletionOrCancellation() {
        let app = FakeAnimationApp()
        let session = ApplicationAnimationSession(backend: app)
        #expect(!app.enhanced)
        #expect(app.reads == 1)
        #expect(app.writes == [false])
        // The same session is retained across frames, windows and retargets.
        #expect(!app.enhanced)
        session.finish()
        #expect(app.enhanced)
        #expect(app.writes == [false, true])
        session.finish()
        #expect(app.writes == [false, true])
    }

    @Test func preservesAnAlreadyDisabledOrUnsupportedMode() {
        let app = FakeAnimationApp()
        app.enhanced = false
        let session = ApplicationAnimationSession(backend: app)
        session.finish()
        #expect(app.reads == 1)
        #expect(app.writes.isEmpty)
        #expect(!app.enhanced)
    }

    @Test func failedDisableDoesNotEnableModeAtCompletion() {
        let app = FakeAnimationApp()
        app.acceptsWrites = false
        let session = ApplicationAnimationSession(backend: app)
        session.finish()
        #expect(app.writes == [false])
    }

    @Test func subsequentTransitionsRestoreTheirOwnOriginalMode() {
        let app = FakeAnimationApp()
        for _ in 0..<3 {
            let session = ApplicationAnimationSession(backend: app)
            #expect(!app.enhanced)
            session.finish()
            #expect(app.enhanced)
        }
        #expect(app.reads == 3)
        #expect(app.writes == [false, true, false, true, false, true])
    }
}

import Foundation
import Testing
import TrippWMCore

struct ScreenWarmthTests {
    private let original = DisplayGammaTable(
        red: [0, 0.4, 1], green: [0, 0.45, 0.95], blue: [0, 0.5, 0.9]
    )

    @Test func offIsIdentityAndMaximumReducesBlueMost() {
        #expect(original.warmed(by: 0) == original)
        let warm = original.warmed(by: 1)
        #expect(warm.red == original.red)
        #expect(abs(warm.green[2] - 0.665) < 0.00001)
        #expect(abs(warm.blue[2] - 0.36) < 0.00001)
        #expect(warm.isValid)
        #expect(warm.red[0] == 0 && warm.green[0] == 0 && warm.blue[0] == 0)
    }

    @Test func strengthIsClampedAndNonfiniteValuesAreOff() {
        #expect(original.warmed(by: -1) == original)
        #expect(original.warmed(by: 2) == original.warmed(by: 1))
        for amount in [Double.nan, .infinity, -.infinity] {
            #expect(ScreenWarmthController.clamp(amount) == 0)
            #expect(original.warmed(by: amount) == original)
        }
    }

    @Test func eachChannelDecreasesMonotonicallyWithoutChangingTheCalibrationShape() {
        var previous = original
        for step in 1...100 {
            let warmed = original.warmed(by: Double(step) / 100)
            #expect(warmed.red == original.red)
            for index in original.green.indices {
                #expect(warmed.green[index] <= previous.green[index])
                #expect(warmed.blue[index] <= previous.blue[index])
            }
            previous = warmed
        }
    }

    @Test func allDisplaysUseTheirOwnOriginalAndRepeatedUpdatesDoNotCompound() {
        let other = DisplayGammaTable(red: [0, 0.8], green: [0, 0.7], blue: [0, 0.6])
        let backend = FakeGammaBackend(tables: [1: original, 2: other])
        let controller = ScreenWarmthController(backend: backend)
        #expect(controller.setAmount(0.5).isEmpty)
        #expect(backend.tables[1] == original.warmed(by: 0.5))
        #expect(backend.tables[2] == other.warmed(by: 0.5))
        #expect(controller.reapply().isEmpty)
        #expect(controller.setAmount(0.8).isEmpty)
        #expect(backend.tables[1] == original.warmed(by: 0.8))
        #expect(backend.reads == [1: 1, 2: 1])
        #expect(controller.restore().isEmpty)
        #expect(backend.tables == [1: original, 2: other])
        #expect(controller.amount == 0)
    }

    @Test func offDoesNotTouchDisplaysAndReenablingCapturesNewProfile() {
        let backend = FakeGammaBackend(tables: [1: original])
        let controller = ScreenWarmthController(backend: backend)
        #expect(controller.reapply().isEmpty)
        #expect(controller.restore().isEmpty)
        #expect(backend.listCalls == 0)
        #expect(backend.reads.isEmpty && backend.writes.isEmpty)
        controller.setAmount(1)
        controller.setAmount(0)
        let newProfile = DisplayGammaTable(red: [0, 0.8], green: [0, 0.9], blue: [0, 1])
        backend.tables[1] = newProfile
        controller.setAmount(0.3)
        #expect(backend.tables[1] == newProfile.warmed(by: 0.3))
        #expect(backend.reads[1] == 2)
        controller.restore()
        #expect(backend.tables[1] == newProfile)
    }

    @Test func newAndReconnectedDisplaysAreCapturedAndWarmed() {
        let backend = FakeGammaBackend(tables: [1: original])
        let controller = ScreenWarmthController(backend: backend)
        controller.setAmount(0.6)
        backend.tables[2] = original
        controller.reapply()
        #expect(backend.tables[2] == original.warmed(by: 0.6))
        backend.tables.removeValue(forKey: 1)
        controller.reapply()
        let replacement = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
        backend.tables[1] = replacement
        controller.reapply()
        #expect(backend.tables[1] == replacement.warmed(by: 0.6))
        controller.restore()
        #expect(backend.tables[1] == replacement)
        #expect(backend.tables[2] == original)
    }

    @Test func failedDisplayDoesNotBlockOthersAndCanRecover() {
        let backend = FakeGammaBackend(tables: [1: original, 2: original])
        backend.readFailures = [1]
        let controller = ScreenWarmthController(backend: backend)
        let issues = controller.setAmount(1)
        #expect(issues.count == 1)
        #expect(issues.first?.display == 1)
        #expect(backend.tables[1] == original)
        #expect(backend.tables[2] == original.warmed(by: 1))
        backend.readFailures = []
        #expect(controller.reapply().isEmpty)
        #expect(backend.tables[1] == original.warmed(by: 1))
    }

    @Test func failedWritesKeepOriginalForRetryIncludingRestoration() {
        let backend = FakeGammaBackend(tables: [1: original])
        let controller = ScreenWarmthController(backend: backend)
        backend.writeFailures = [1]
        #expect(controller.setAmount(0.5).count == 1)
        backend.writeFailures = []
        #expect(controller.reapply().isEmpty)
        #expect(backend.tables[1] == original.warmed(by: 0.5))
        backend.writeFailures = [1]
        #expect(controller.restore().count == 1)
        #expect(backend.tables[1] != original)
        backend.writeFailures = []
        #expect(controller.restore().isEmpty)
        #expect(backend.tables[1] == original)
        let writeCount = backend.writes.count
        controller.restore()
        #expect(backend.writes.count == writeCount)
    }

    @Test func displayEnumerationFailurePreservesOriginalsForRestore() {
        let backend = FakeGammaBackend(tables: [1: original])
        let controller = ScreenWarmthController(backend: backend)
        controller.setAmount(1)
        backend.listFails = true
        let issues = controller.restore()
        #expect(issues.count == 1 && issues.first?.display == nil)
        backend.listFails = false
        #expect(controller.restore().isEmpty)
        #expect(backend.tables[1] == original)
    }

    @Test func invalidCurvesAreNeverWritten() {
        let invalid = [
            DisplayGammaTable(red: [], green: [], blue: []),
            DisplayGammaTable(red: [0, 1], green: [1], blue: [1]),
            DisplayGammaTable(red: [.nan], green: [1], blue: [1]),
            DisplayGammaTable(red: [1], green: [.infinity], blue: [1]),
            DisplayGammaTable(red: [1], green: [1], blue: [-0.1]),
            DisplayGammaTable(red: [1.1], green: [1], blue: [1]),
        ]
        for table in invalid {
            let backend = FakeGammaBackend(tables: [1: table])
            let controller = ScreenWarmthController(backend: backend)
            #expect(!table.isValid)
            #expect(controller.setAmount(1).count == 1)
            #expect(backend.writes.isEmpty)
            controller.restore()
            #expect(backend.writes.isEmpty)
        }
    }
}

private final class FakeGammaBackend: DisplayGammaBackend {
    struct Failure: Error {}
    var tables: [UInt32: DisplayGammaTable]
    var reads: [UInt32: Int] = [:]
    var writes: [UInt32] = []
    var readFailures: Set<UInt32> = []
    var writeFailures: Set<UInt32> = []
    var listFails = false
    var listCalls = 0

    init(tables: [UInt32: DisplayGammaTable]) { self.tables = tables }

    func connectedDisplays() throws -> [UInt32] {
        listCalls += 1
        if listFails { throw Failure() }
        return tables.keys.sorted()
    }

    func readGamma(for display: UInt32) throws -> DisplayGammaTable {
        reads[display, default: 0] += 1
        if readFailures.contains(display) { throw Failure() }
        guard let table = tables[display] else { throw Failure() }
        return table
    }

    func writeGamma(_ table: DisplayGammaTable, for display: UInt32) throws {
        if writeFailures.contains(display) { throw Failure() }
        writes.append(display)
        tables[display] = table
    }
}

import Foundation
import Testing
import TrippWMCore

private final class WrittenValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

struct LatestValueWorkerTests {
    @Test func slowWriterDoesNotBlockSubmissionOrReplayObsoleteFrames() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let written = WrittenValues()
        let worker = LatestValueWorker<Int> { value in
            if value == 1 {
                started.signal()
                release.wait()
            }
            written.append(value)
        }
        worker.submit(1)
        #expect(started.wait(timeout: .now() + 5) == .success)
        worker.submit(2)
        worker.submit(3)
        #expect(written.snapshot.isEmpty)
        release.signal()
        worker.wait()
        #expect(written.snapshot == [1, 3])
        worker.submit(4)
        worker.wait()
        #expect(written.snapshot == [1, 3, 4])
    }

    @Test func cancellationDropsPendingFramesBeforeLayoutReconciliation() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let written = WrittenValues()
        let worker = LatestValueWorker<Int> { value in
            started.signal()
            release.wait()
            written.append(value)
        }
        worker.submit(1)
        #expect(started.wait(timeout: .now() + 5) == .success)
        worker.submit(2)
        worker.cancel()
        release.signal()
        worker.wait()
        written.append(3)
        #expect(written.snapshot == [1, 3])
    }

    @Test func applicationsWriteIndependently() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let written = WrittenValues()
        let slow = LatestValueWorker<Int> { value in
            started.signal()
            release.wait()
            written.append(value)
        }
        let other = LatestValueWorker<Int> { written.append($0) }
        slow.submit(1)
        #expect(started.wait(timeout: .now() + 5) == .success)
        other.submit(2)
        other.wait()
        #expect(written.snapshot == [2])
        release.signal()
        slow.wait()
        #expect(written.snapshot == [2, 1])
    }
}

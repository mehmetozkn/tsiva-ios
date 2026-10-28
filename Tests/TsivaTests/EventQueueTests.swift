import XCTest
@testable import Tsiva

final class EventQueueTests: XCTestCase {
    private func makeQueue(
        sender: MockSender,
        batchSize: Int = 10,
        maxQueueSize: Int = 100,
        maxRetries: Int = 3,
        clock: TestClock = TestClock()
    ) -> EventQueue {
        EventQueue(
            sender: sender,
            batchSize: batchSize,
            maxQueueSize: maxQueueSize,
            maxRetries: maxRetries,
            logger: TsivaLogger(level: .none),
            now: { clock.now }
        )
    }

    func testFlushSendsInOrderedBatches() async {
        let sender = MockSender()
        let queue = makeQueue(sender: sender, batchSize: 2)
        for index in 0..<5 { await queue.enqueue(.fixture("e\(index)")) }
        await queue.flush()

        XCTAssertTrue(sender.batches.allSatisfy { $0.count <= 2 })
        XCTAssertEqual(sender.sentEvents.map(\.name), ["e0", "e1", "e2", "e3", "e4"])
        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
    }

    func testReachingBatchSizeTriggersUpload() async {
        let sender = MockSender()
        let queue = makeQueue(sender: sender, batchSize: 3)
        for index in 0..<3 { await queue.enqueue(.fixture("e\(index)")) }

        await waitUntil { sender.sentEvents.count == 3 }
    }

    func testRetryableFailureKeepsEventsAndBacksOff() async {
        let sender = MockSender(results: [.retryable(reason: "offline", retryAfter: nil)])
        let clock = TestClock()
        let queue = makeQueue(sender: sender, clock: clock)
        await queue.enqueue(.fixture("a"))

        await queue.flush()
        var remaining = await queue.count
        XCTAssertEqual(remaining, 1)
        let retryDate = await queue.nextRetryDate
        XCTAssertEqual(retryDate, clock.now.addingTimeInterval(2))

        // Automatic flushes wait for the backoff to pass.
        await queue.flush(ignoringBackoff: false)
        XCTAssertEqual(sender.batches.count, 1)

        clock.advance(by: 2)
        await queue.flush(ignoringBackoff: false)
        remaining = await queue.count
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(sender.batches.count, 2)
        XCTAssertEqual(sender.batches.last?.map(\.name), ["a"])
    }

    func testRetryAfterHeaderIsHonoredAndCapped() async {
        let sender = MockSender(results: [
            .retryable(reason: "429", retryAfter: 60),
            .retryable(reason: "429", retryAfter: 100_000)
        ])
        let clock = TestClock()
        let queue = makeQueue(sender: sender, clock: clock)
        await queue.enqueue(.fixture())

        await queue.flush()
        var retryDate = await queue.nextRetryDate
        XCTAssertEqual(retryDate, clock.now.addingTimeInterval(60))

        await queue.flush()
        retryDate = await queue.nextRetryDate
        XCTAssertEqual(retryDate, clock.now.addingTimeInterval(EventQueue.maxBackoff))
    }

    func testBatchIsDroppedAfterMaxRetries() async {
        let failure = DeliveryResult.retryable(reason: "down", retryAfter: nil)
        let sender = MockSender(results: [failure, failure, failure])
        let queue = makeQueue(sender: sender, maxRetries: 2)
        await queue.enqueue(.fixture("lost"))

        for _ in 0..<3 { await queue.flush() }

        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(sender.batches.count, 3)

        // The next batch starts with a clean retry budget.
        await queue.enqueue(.fixture("next"))
        await queue.flush()
        XCTAssertEqual(sender.batches.last?.map(\.name), ["next"])
        let retryDate = await queue.nextRetryDate
        XCTAssertNil(retryDate)
    }

    func testRejectedBatchIsDroppedAndFlushContinues() async {
        let sender = MockSender(results: [.rejected(reason: "HTTP 400")])
        let queue = makeQueue(sender: sender, batchSize: 1)
        await queue.enqueue(.fixture("bad"))
        await queue.enqueue(.fixture("good"))

        await queue.flush()

        XCTAssertEqual(sender.batches.map { $0.map(\.name) }.suffix(2), [["bad"], ["good"]])
        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
    }

    func testOverflowDropsOldestEvents() async {
        let sender = MockSender()
        let queue = makeQueue(sender: sender, batchSize: 100, maxQueueSize: 3)
        for index in 0..<5 { await queue.enqueue(.fixture("e\(index)")) }
        await queue.flush()

        XCTAssertEqual(sender.sentEvents.map(\.name), ["e2", "e3", "e4"])
    }

    func testConcurrentFlushesSendEachEventOnce() async {
        let sender = MockSender()
        let queue = makeQueue(sender: sender, batchSize: 100)
        for index in 0..<50 { await queue.enqueue(.fixture("e\(index)")) }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 { group.addTask { await queue.flush() } }
        }

        XCTAssertEqual(sender.sentEvents.count, 50)
        XCTAssertEqual(Set(sender.sentEvents.map(\.id)).count, 50)
    }
}

import Foundation

/// In-memory queue that batches events and hands them to an `EventSender`.
///
/// - Uploads happen in batches of at most `batchSize` events, in the order the events were tracked.
/// - Retryable failures put the batch back at the head of the queue and pause automatic uploads with
///   exponential backoff. After `maxRetries` failed retries the batch is dropped.
/// - When the queue holds more than `maxQueueSize` events, the oldest ones are dropped.
actor EventQueue {
    private let sender: EventSender
    private let batchSize: Int
    private let maxQueueSize: Int
    private let maxRetries: Int
    private let logger: TsivaLogger
    private let now: @Sendable () -> Date

    private var events: [TsivaEvent] = []
    private var isFlushing = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var failedAttempts = 0
    private(set) var nextRetryDate: Date?

    init(
        sender: EventSender,
        batchSize: Int,
        maxQueueSize: Int,
        maxRetries: Int,
        logger: TsivaLogger,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sender = sender
        self.batchSize = batchSize
        self.maxQueueSize = maxQueueSize
        self.maxRetries = maxRetries
        self.logger = logger
        self.now = now
    }

    var count: Int { events.count }

    func enqueue(_ event: TsivaEvent) {
        events.append(event)
        dropOverflow()
        logger.debug("Queued \"\(event.name)\" (\(events.count) pending)")

        if events.count >= batchSize {
            Task { await self.flush(ignoringBackoff: false) }
        }
    }

    /// Uploads queued events until the queue is empty or a delivery fails.
    ///
    /// If an upload is already running, waits for it to finish instead of starting a second one.
    /// - Parameter ignoringBackoff: `true` for explicit flushes; automatic ones pass `false` and skip
    ///   while a retry backoff is in effect.
    func flush(ignoringBackoff: Bool = true) async {
        if isFlushing {
            await withCheckedContinuation { flushWaiters.append($0) }
            return
        }
        isFlushing = true

        while !events.isEmpty {
            if !ignoringBackoff, let nextRetryDate, now() < nextRetryDate {
                break
            }

            let batch = Array(events.prefix(batchSize))
            events.removeFirst(batch.count)

            guard await deliver(batch) else { break }
        }

        isFlushing = false
        let waiters = flushWaiters
        flushWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Sends one batch. Returns `true` if the flush loop may continue with the next batch.
    private func deliver(_ batch: [TsivaEvent]) async -> Bool {
        switch await sender.send(batch) {
        case .success:
            logger.debug("Sent \(batch.count) event(s)")
            resetBackoff()
            return true

        case .rejected(let reason):
            logger.error("Dropped \(batch.count) event(s) rejected by the server: \(reason)")
            resetBackoff()
            return true

        case .retryable(let reason, let retryAfter):
            failedAttempts += 1
            if failedAttempts > maxRetries {
                logger.error("Dropped \(batch.count) event(s) after \(maxRetries) retries: \(reason)")
                resetBackoff()
                return false
            }
            events.insert(contentsOf: batch, at: 0)
            dropOverflow()
            let delay = min(retryAfter ?? backoffDelay(forAttempt: failedAttempts), Self.maxBackoff)
            nextRetryDate = now().addingTimeInterval(delay)
            logger.warning("Upload failed (\(reason)); retry \(failedAttempts)/\(maxRetries) in \(Int(delay))s")
            return false
        }
    }

    /// Upper bound for any retry delay, including a server-provided `Retry-After`.
    static let maxBackoff: TimeInterval = 300

    /// 2s, 4s, 8s, ... capped at `maxBackoff`.
    func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        min(pow(2, Double(attempt)), Self.maxBackoff)
    }

    private func resetBackoff() {
        failedAttempts = 0
        nextRetryDate = nil
    }

    private func dropOverflow() {
        let overflow = events.count - maxQueueSize
        guard overflow > 0 else { return }
        events.removeFirst(overflow)
        logger.warning("Queue is full; dropped \(overflow) oldest event(s)")
    }
}

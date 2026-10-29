import Foundation

/// The configured SDK instance behind the `Tsiva` facade.
///
/// `track` is synchronous and cheap: it builds the event on the caller's thread and pushes it onto an
/// ordered command stream. A single consumer task drains that stream into the `EventQueue`, which keeps
/// events in the order they were tracked.
final class TsivaClient: Sendable {
    let configuration: TsivaConfiguration
    let anonymousId: String
    let sessionId: String
    let context: TsivaContext
    let queue: EventQueue

    private let logger: TsivaLogger
    private let sanitizer: EventSanitizer
    private let commands: AsyncStream<Command>.Continuation
    private let tasks: [Task<Void, Never>]
    private let lifecycleObserver: Locked<LifecycleObserver?>
    let crashReporter: CrashReporter?

    private enum Command: Sendable {
        case track(TsivaEvent)
        case flush(CheckedContinuation<Void, Never>)
    }

    init(
        configuration: TsivaConfiguration,
        sender: EventSender? = nil,
        crashSender: CrashSender? = nil,
        crashDirectory: URL? = CrashReporter.defaultDirectory(),
        defaults: UserDefaults = .standard,
        context: TsivaContext = .current()
    ) {
        let configuration = configuration.validated()
        let logger = TsivaLogger(level: configuration.logLevel)
        let transport = NetworkTransport(
            apiKey: configuration.apiKey,
            endpoint: configuration.endpoint,
            timeout: configuration.requestTimeout
        )
        let sender = sender ?? transport
        let queue = EventQueue(
            sender: sender,
            batchSize: configuration.flushAt,
            maxQueueSize: configuration.maxQueueSize,
            maxRetries: configuration.maxRetries,
            logger: logger
        )

        self.configuration = configuration
        self.logger = logger
        self.sanitizer = EventSanitizer(redactedKeys: configuration.redactedPropertyKeys)
        self.anonymousId = AnonymousID.loadOrCreate(in: defaults)
        self.sessionId = UUID().uuidString
        self.context = context
        self.queue = queue

        let (stream, commands) = AsyncStream<Command>.makeStream()
        self.commands = commands

        let consumer = Task {
            for await command in stream {
                switch command {
                case .track(let event):
                    await queue.enqueue(event)
                case .flush(let continuation):
                    await queue.flush()
                    continuation.resume()
                }
            }
        }
        let interval = UInt64(configuration.flushInterval * 1_000_000_000)
        let timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await queue.flush(ignoringBackoff: false)
            }
        }
        var tasks = [consumer, timer]
        self.lifecycleObserver = Locked(nil)

        if configuration.crashReportingEnabled, let crashDirectory {
            let reporter = CrashReporter(directory: crashDirectory, logger: logger)
            reporter.start(session: CrashSession(
                anonymousId: anonymousId,
                sessionId: sessionId,
                context: context,
                executableName: Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
            ))
            let crashSender = crashSender ?? transport
            tasks.append(Task { await reporter.sendPending(using: crashSender) })
            self.crashReporter = reporter
        } else {
            self.crashReporter = nil
        }
        self.tasks = tasks

        if configuration.flushOnBackground {
            let observer = LifecycleObserver { [weak self] in self }
            lifecycleObserver.withLock { $0 = observer }
        }
    }

    func track(_ name: String, properties: [String: TsivaValue]) {
        guard let cleanName = sanitizer.sanitizeName(name) else {
            logger.error("Ignored event with an empty or too long name (max \(EventSanitizer.maxNameLength) characters)")
            return
        }

        var event = TsivaEvent(
            name: cleanName,
            properties: sanitizer.sanitizeProperties(properties),
            anonymousId: anonymousId,
            sessionId: sessionId,
            context: context
        )

        if let beforeSend = configuration.beforeSend {
            guard let modified = beforeSend(event) else {
                logger.debug("Event \"\(cleanName)\" dropped by beforeSend")
                return
            }
            event = modified
        }

        commands.yield(.track(event))
    }

    /// Waits until every event tracked before this call has been handed to the queue and an upload attempt finished.
    func flush() async {
        await withCheckedContinuation { continuation in
            if case .terminated = commands.yield(.flush(continuation)) {
                continuation.resume()
            }
        }
    }

    deinit {
        commands.finish()
        tasks.forEach { $0.cancel() }
    }

    /// Stops background work. Events still in memory are discarded.
    func shutdown() {
        commands.finish()
        tasks.forEach { $0.cancel() }
        lifecycleObserver.withLock { $0 = nil }
    }
}

/// Persists a random install identifier. It is not derived from any device or advertising identifier,
/// and it is reset when the app is reinstalled.
enum AnonymousID {
    static let defaultsKey = "com.tsiva.anonymous_id"

    static func loadOrCreate(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}

import Foundation

/// The configured SDK instance behind the `Tsiva` facade.
///
/// `track` is synchronous and cheap: it builds the event on the caller's thread and pushes it onto an
/// ordered command stream. A single consumer task drains that stream into the `EventQueue`, which keeps
/// events in the order they were tracked.
final class TsivaClient: Sendable {
    let configuration: TsivaConfiguration
    let sessionId: String
    let context: TsivaContext
    let queue: EventQueue

    private let logger: TsivaLogger
    private let sanitizer: EventSanitizer
    private let commands: AsyncStream<Command>.Continuation
    private let tasks: [Task<Void, Never>]
    private let lifecycleObserver: Locked<LifecycleObserver?>
    let crashReporter: CrashReporter?
    private let identity: Locked<Identity>
    private let defaults: Locked<UserDefaults>
    private let executableName: String

    private struct Identity {
        var anonymousId: String
        var userId: String?
    }

    var anonymousId: String { identity.withLock { $0.anonymousId } }
    var userId: String? { identity.withLock { $0.userId } }

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
        let initialIdentity = Identity(anonymousId: AnonymousID.loadOrCreate(in: defaults), userId: UserID.load(from: defaults))
        let executableName = Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName
        let sessionId = UUID().uuidString
        self.identity = Locked(initialIdentity)
        self.defaults = Locked(defaults)
        self.executableName = executableName
        self.sessionId = sessionId
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
                anonymousId: initialIdentity.anonymousId,
                sessionId: sessionId,
                userId: initialIdentity.userId,
                context: context,
                executableName: executableName
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

        let current = identity.withLock { $0 }
        var event = TsivaEvent(
            name: cleanName,
            properties: sanitizer.sanitizeProperties(properties),
            anonymousId: current.anonymousId,
            sessionId: sessionId,
            userId: current.userId,
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

    /// Attaches `userId` to every event tracked from now on, and remembers it across launches.
    func identify(_ userId: String) {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= UserID.maxLength else {
            logger.error("identify() ignored: userId must be 1 to \(UserID.maxLength) characters")
            return
        }
        let changed = identity.withLock { identity -> Bool in
            defer { identity.userId = trimmed }
            return identity.userId != trimmed
        }
        guard changed else { return }
        defaults.withLock { UserID.save(trimmed, in: $0) }
        crashReporter?.saveSession(crashSession())
        // Tells the backend right away which user this install belongs to, so events the install sent before
        // being identified are attributed too, even if no other event follows. The backend does not store it
        // as an event.
        track(UserID.identifyEvent, properties: [:])
        logger.debug("Identified user")
    }

    /// Forgets the user and starts a new anonymous identity, e.g. when the user logs out.
    func reset() {
        let anonymousId = defaults.withLock { defaults in
            UserID.save(nil, in: defaults)
            return AnonymousID.regenerate(in: defaults)
        }
        identity.withLock { $0 = Identity(anonymousId: anonymousId, userId: nil) }
        crashReporter?.saveSession(crashSession())
        logger.debug("Identity reset")
    }

    private func crashSession() -> CrashSession {
        let current = identity.withLock { $0 }
        return CrashSession(
            anonymousId: current.anonymousId,
            sessionId: sessionId,
            userId: current.userId,
            context: context,
            executableName: executableName
        )
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
        return regenerate(in: defaults)
    }

    static func regenerate(in defaults: UserDefaults) -> String {
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}

/// The identifier set with `Tsiva.identify(userId:)`, persisted so events of later launches carry it too.
enum UserID {
    static let defaultsKey = "com.tsiva.user_id"
    static let maxLength = 128
    /// Reserved event name sent when the user id changes.
    static let identifyEvent = "$identify"

    static func load(from defaults: UserDefaults) -> String? {
        defaults.string(forKey: defaultsKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ userId: String?, in defaults: UserDefaults) {
        if let userId {
            defaults.set(userId, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}

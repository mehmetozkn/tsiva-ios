import Foundation

/// Settings for the Tsiva SDK. Only `apiKey` and `endpoint` are required; the rest have sensible defaults.
public struct TsivaConfiguration: Sendable {
    /// Project-scoped ingestion key. It is shipped inside the app binary and must not be treated as a secret.
    public var apiKey: String

    /// Base URL of the Tsiva API. Events are posted to `<endpoint>/v1/events`.
    public var endpoint: URL

    /// Number of queued events that triggers an automatic upload. Also the maximum number of events per request.
    public var flushAt: Int

    /// Interval, in seconds, between periodic uploads of queued events.
    public var flushInterval: TimeInterval

    /// Maximum number of events kept in memory. When exceeded, the oldest events are dropped.
    public var maxQueueSize: Int

    /// How many times a batch is retried after retryable failures (network errors, 429, 5xx) before it is dropped.
    public var maxRetries: Int

    /// Timeout, in seconds, of a single upload request.
    public var requestTimeout: TimeInterval

    /// Property keys whose values are never sent. Matching is case-insensitive and ignores `_`, `-` and spaces,
    /// and a key matches if it *contains* one of these entries (so `"token"` also removes `"refresh_token"`).
    public var redactedPropertyKeys: Set<String>

    /// Called for every event right before it is queued. Return a modified event, or `nil` to drop it.
    /// Runs on the thread that called `track`, so keep it fast.
    public var beforeSend: (@Sendable (TsivaEvent) -> TsivaEvent?)?

    /// Verbosity of the SDK's own console output. The API key is never logged.
    public var logLevel: TsivaLogLevel

    /// When `true`, queued events are flushed as the app moves to the background (iOS only).
    public var flushOnBackground: Bool

    /// When `true`, crashes (fatal signals and uncaught Objective-C exceptions) are recorded and sent on the
    /// next launch. Only one crash reporter can be active in an app; disable this if you use another one.
    public var crashReportingEnabled: Bool

    public init(
        apiKey: String,
        endpoint: URL,
        flushAt: Int = 20,
        flushInterval: TimeInterval = 30,
        maxQueueSize: Int = 1000,
        maxRetries: Int = 3,
        requestTimeout: TimeInterval = 10,
        redactedPropertyKeys: Set<String> = TsivaConfiguration.defaultRedactedPropertyKeys,
        beforeSend: (@Sendable (TsivaEvent) -> TsivaEvent?)? = nil,
        logLevel: TsivaLogLevel = .error,
        flushOnBackground: Bool = true,
        crashReportingEnabled: Bool = true
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.flushAt = flushAt
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.maxRetries = maxRetries
        self.requestTimeout = requestTimeout
        self.redactedPropertyKeys = redactedPropertyKeys
        self.beforeSend = beforeSend
        self.logLevel = logLevel
        self.flushOnBackground = flushOnBackground
        self.crashReportingEnabled = crashReportingEnabled
    }

    /// Property keys removed by default because they commonly carry credentials or personal data.
    public static let defaultRedactedPropertyKeys: Set<String> = [
        "password", "passwd", "secret", "token", "apikey", "authorization", "cookie",
        "creditcard", "cardnumber", "cvv", "cvc", "iban", "ssn", "email", "phone"
    ]

    /// Clamps out-of-range values so a bad setting cannot stall or flood the SDK.
    func validated() -> TsivaConfiguration {
        var copy = self
        copy.flushAt = min(max(flushAt, 1), 100)
        copy.flushInterval = max(flushInterval, 1)
        copy.maxQueueSize = max(maxQueueSize, copy.flushAt)
        copy.maxRetries = max(maxRetries, 0)
        copy.requestTimeout = max(requestTimeout, 1)
        return copy
    }
}

/// Verbosity of the SDK's console output.
public enum TsivaLogLevel: Int, Sendable, Comparable {
    case none = 0
    case error = 1
    case warning = 2
    case debug = 3

    public static func < (lhs: TsivaLogLevel, rhs: TsivaLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

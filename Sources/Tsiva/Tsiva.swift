import Foundation

/// Entry point of the Tsiva SDK.
///
/// ```swift
/// import Tsiva
///
/// Tsiva.configure(
///     apiKey: "YOUR_PROJECT_KEY",
///     endpoint: URL(string: "https://api.example.com")!
/// )
///
/// Tsiva.track("checkout_started", properties: ["payment_method": "card"])
/// ```
///
/// All methods are thread-safe and never throw: misuse is reported through the SDK log instead of
/// crashing the host app.
public enum Tsiva {
    private static let client = Locked<TsivaClient?>(nil)

    /// Starts the SDK with the default settings. Call once, as early as possible (for example in
    /// `application(_:didFinishLaunchingWithOptions:)` or your `App` initializer).
    public static func configure(apiKey: String, endpoint: URL) {
        configure(TsivaConfiguration(apiKey: apiKey, endpoint: endpoint))
    }

    /// Starts the SDK with custom settings. Calls after the first successful one are ignored.
    public static func configure(_ configuration: TsivaConfiguration) {
        let logger = TsivaLogger(level: configuration.logLevel)

        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.error("configure() ignored: apiKey is empty")
            return
        }
        guard let scheme = configuration.endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            logger.error("configure() ignored: endpoint must be an http(s) URL")
            return
        }

        install { TsivaClient(configuration: configuration) }
    }

    /// Records an event. Does nothing (apart from a log message) if the SDK is not configured.
    ///
    /// - Parameters:
    ///   - name: Event name, up to 128 characters. Prefer `snake_case`, e.g. `"checkout_started"`.
    ///   - properties: Optional details. Keys matching `redactedPropertyKeys` are removed before sending.
    public static func track(_ name: String, properties: [String: TsivaValue] = [:]) {
        guard let client = current else {
            TsivaLogger(level: .warning).warning("track(\"\(name)\") ignored: call Tsiva.configure() first")
            return
        }
        client.track(name, properties: properties)
    }

    /// Uploads all queued events now and waits for the attempt to finish.
    /// Not required in normal use: events are sent automatically in batches.
    public static func flush() async {
        await current?.flush()
    }

    /// Whether `configure` has been called successfully.
    public static var isConfigured: Bool {
        current != nil
    }

    /// Links all following events to your own identifier for the user, e.g. an account id after login. The
    /// identifier is remembered across launches until `reset()` is called. Do not pass personal data such as an
    /// email address; use an opaque id.
    public static func identify(userId: String) {
        guard let client = current else {
            TsivaLogger(level: .warning).warning("identify() ignored: call Tsiva.configure() first")
            return
        }
        client.identify(userId)
    }

    /// Forgets the identified user and starts a new anonymous identity. Call it when the user logs out, so the
    /// next user's events are not attributed to them.
    public static func reset() {
        current?.reset()
    }

    /// The identifier set with `identify(userId:)`, or `nil`.
    public static var userId: String? {
        current?.userId
    }

    /// The random install identifier attached to every event, or `nil` before `configure`.
    /// Useful for looking up a specific install's events when handling a support request.
    public static var anonymousId: String? {
        current?.anonymousId
    }

    private static var current: TsivaClient? {
        client.withLock { $0 }
    }

    /// Installs a client unless one is already running. Returns `false` if a client was already installed.
    @discardableResult
    static func install(_ makeClient: () -> TsivaClient) -> Bool {
        client.withLock { client in
            if let existing = client {
                TsivaLogger(level: existing.configuration.logLevel)
                    .warning("configure() ignored: Tsiva is already configured")
                return false
            }
            client = makeClient()
            return true
        }
    }

    /// Stops and removes the current client. Intended for tests.
    static func removeClient() {
        let removed = client.withLock { client -> TsivaClient? in
            defer { client = nil }
            return client
        }
        removed?.shutdown()
    }
}

import Foundation

/// A single analytics event, as it is sent to the Tsiva API.
public struct TsivaEvent: Sendable, Equatable, Codable {
    /// Unique identifier, used by the backend to deduplicate retried deliveries.
    public let id: UUID
    public var name: String
    public let timestamp: Date
    public var properties: [String: TsivaValue]
    /// Random, install-scoped identifier. Not tied to the device or the user's identity.
    public let anonymousId: String
    /// Identifier of the SDK session the event was recorded in. A new session starts on each `configure`.
    public let sessionId: String
    /// Your own identifier for the user, set with `Tsiva.identify(userId:)`. Nil until then.
    public let userId: String?
    public let context: TsivaContext

    public init(
        id: UUID = UUID(),
        name: String,
        timestamp: Date = Date(),
        properties: [String: TsivaValue] = [:],
        anonymousId: String,
        sessionId: String,
        userId: String? = nil,
        context: TsivaContext
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.properties = properties
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.userId = userId
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case timestamp
        case properties
        case anonymousId = "anonymous_id"
        case sessionId = "session_id"
        case userId = "user_id"
        case context
    }
}

/// Metadata shared by every event: which SDK, app and OS produced it.
public struct TsivaContext: Sendable, Equatable, Codable {
    public struct SDK: Sendable, Equatable, Codable {
        public var name: String
        public var version: String
    }

    public struct App: Sendable, Equatable, Codable {
        public var bundleId: String?
        public var version: String?
        public var build: String?

        enum CodingKeys: String, CodingKey {
            case bundleId = "bundle_id"
            case version
            case build
        }
    }

    public struct OS: Sendable, Equatable, Codable {
        public var name: String
        public var version: String
    }

    public struct Device: Sendable, Equatable, Codable {
        /// Hardware model identifier such as `iPhone16,2`.
        public var model: String
    }

    public var sdk: SDK
    public var app: App
    public var os: OS
    public var device: Device
    public var locale: String
    public var timezone: String

    public init(sdk: SDK, app: App, os: OS, device: Device, locale: String, timezone: String) {
        self.sdk = sdk
        self.app = app
        self.os = os
        self.device = device
        self.locale = locale
        self.timezone = timezone
    }
}

extension TsivaContext {
    /// Collects the context of the running process.
    static func current(bundle: Bundle = .main) -> TsivaContext {
        let info = bundle.infoDictionary ?? [:]
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        return TsivaContext(
            sdk: SDK(name: TsivaSDK.name, version: TsivaSDK.version),
            app: App(
                bundleId: bundle.bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String
            ),
            os: OS(
                name: osName,
                version: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            ),
            device: Device(model: hardwareModel()),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier
        )
    }

    private static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    private static func hardwareModel() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return model
        }
        #endif
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? "unknown" : model
    }
}

/// Identity of this SDK, reported in every event and in the `User-Agent` header.
public enum TsivaSDK {
    public static let name = "tsiva-ios"
    public static let version = "0.3.1"
}

import Foundation

/// Outcome of trying to deliver one batch of events.
enum DeliveryResult: Sendable, Equatable {
    case success
    /// Temporary failure (network error, 429, 5xx). The batch should be kept and retried later.
    case retryable(reason: String, retryAfter: TimeInterval?)
    /// Permanent failure (malformed payload, invalid key, ...). Retrying would not help, so the batch is dropped.
    case rejected(reason: String)
}

/// Anything that can deliver a batch of events. Lets tests replace the network with a mock.
protocol EventSender: Sendable {
    func send(_ events: [TsivaEvent]) async -> DeliveryResult
}

/// Minimal HTTP abstraction over `URLSession`, so request handling can be tested without a server.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: nil)
    }
}

/// Request body of `POST /v1/events`.
struct EventBatch: Codable, Equatable {
    let sentAt: Date
    let events: [TsivaEvent]

    enum CodingKeys: String, CodingKey {
        case sentAt = "sent_at"
        case events
    }
}

/// Sends event batches to the Tsiva API over HTTP.
struct NetworkTransport: EventSender {
    static let apiKeyHeader = "X-Tsiva-Api-Key"

    let apiKey: String
    let endpoint: URL
    let timeout: TimeInterval
    let client: HTTPClient
    let now: @Sendable () -> Date

    init(
        apiKey: String,
        endpoint: URL,
        timeout: TimeInterval,
        client: HTTPClient = URLSessionHTTPClient(session: NetworkTransport.makeSession()),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.timeout = timeout
        self.client = client
        self.now = now
    }

    var eventsURL: URL {
        endpoint.appendingPathComponent("v1").appendingPathComponent("events")
    }

    func makeRequest(for events: [TsivaEvent]) throws -> URLRequest {
        var request = URLRequest(url: eventsURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: Self.apiKeyHeader)
        request.setValue("\(TsivaSDK.name)/\(TsivaSDK.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try TsivaJSON.makeEncoder().encode(EventBatch(sentAt: now(), events: events))
        return request
    }

    func send(_ events: [TsivaEvent]) async -> DeliveryResult {
        let request: URLRequest
        do {
            request = try makeRequest(for: events)
        } catch {
            return .rejected(reason: "Could not encode events: \(error.localizedDescription)")
        }

        let response: URLResponse
        do {
            (_, response) = try await client.send(request)
        } catch {
            return .retryable(reason: "Network error: \(error.localizedDescription)", retryAfter: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            return .retryable(reason: "Response was not HTTP", retryAfter: nil)
        }
        return Self.classify(http)
    }

    static func classify(_ response: HTTPURLResponse) -> DeliveryResult {
        let status = response.statusCode
        switch status {
        case 200..<300:
            return .success
        case 408, 429, 500..<600:
            let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .retryable(reason: "HTTP \(status)", retryAfter: retryAfter)
        default:
            return .rejected(reason: "HTTP \(status)")
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// JSON settings shared by the SDK. Dates are ISO 8601 in UTC with millisecond precision.
enum TsivaJSON {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            return try dateStyle.parse(string)
        }
        return decoder
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(secondsFromGMT: 0)!)
}

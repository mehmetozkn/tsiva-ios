import Foundation
import XCTest
@testable import Tsiva

/// Records delivered batches and replays scripted results (defaults to `.success`).
final class MockSender: EventSender {
    private let state = Locked<(results: [DeliveryResult], batches: [[TsivaEvent]])>(([], []))

    init(results: [DeliveryResult] = []) {
        state.withLock { $0.results = results }
    }

    var batches: [[TsivaEvent]] { state.withLock { $0.batches } }
    var sentEvents: [TsivaEvent] { batches.flatMap { $0 } }

    func enqueueResults(_ results: DeliveryResult...) {
        state.withLock { $0.results.append(contentsOf: results) }
    }

    func send(_ events: [TsivaEvent]) async -> DeliveryResult {
        state.withLock { state in
            state.batches.append(events)
            return state.results.isEmpty ? .success : state.results.removeFirst()
        }
    }
}

/// Returns a scripted response, or throws `error`, and records every request.
final class MockHTTPClient: HTTPClient {
    private let state = Locked<[URLRequest]>([])
    let statusCode: Int
    let headers: [String: String]
    let error: Error?

    init(statusCode: Int = 202, headers: [String: String] = [:], error: Error? = nil) {
        self.statusCode = statusCode
        self.headers = headers
        self.error = error
    }

    var requests: [URLRequest] { state.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        state.withLock { $0.append(request) }
        if let error { throw error }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        return (Data(), response)
    }
}

/// A manually advanced clock.
final class TestClock: Sendable {
    private let date = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { date.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        date.withLock { $0.addTimeInterval(interval) }
    }
}

extension TsivaContext {
    static let fixture = TsivaContext(
        sdk: .init(name: TsivaSDK.name, version: TsivaSDK.version),
        app: .init(bundleId: "com.example.app", version: "1.2.0", build: "42"),
        os: .init(name: "iOS", version: "18.0.0"),
        device: .init(model: "iPhone16,2"),
        locale: "tr_TR",
        timezone: "Europe/Istanbul"
    )
}

extension TsivaEvent {
    static func fixture(_ name: String = "test_event", properties: [String: TsivaValue] = [:]) -> TsivaEvent {
        TsivaEvent(
            name: name,
            properties: properties,
            anonymousId: "anon-1",
            sessionId: "session-1",
            context: .fixture
        )
    }
}

extension TsivaConfiguration {
    static func test(
        flushAt: Int = 20,
        maxRetries: Int = 3,
        beforeSend: (@Sendable (TsivaEvent) -> TsivaEvent?)? = nil
    ) -> TsivaConfiguration {
        TsivaConfiguration(
            apiKey: "test-key",
            endpoint: URL(string: "https://api.example.com")!,
            flushAt: flushAt,
            flushInterval: 3600,
            maxRetries: maxRetries,
            beforeSend: beforeSend,
            logLevel: .none,
            flushOnBackground: false,
            crashReportingEnabled: false
        )
    }
}

func makeTestDefaults() -> UserDefaults {
    let name = "TsivaTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Polls `condition` until it is true or the timeout expires.
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Condition not met within \(timeout)s", file: file, line: line)
}

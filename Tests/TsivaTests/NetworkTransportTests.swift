import XCTest
@testable import Tsiva

final class NetworkTransportTests: XCTestCase {
    private let sentAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTransport(client: HTTPClient, endpoint: String = "https://api.example.com") -> NetworkTransport {
        let sentAt = sentAt
        return NetworkTransport(
            apiKey: "project-key",
            endpoint: URL(string: endpoint)!,
            timeout: 7,
            client: client,
            now: { sentAt }
        )
    }

    func testRequestShape() async throws {
        let client = MockHTTPClient()
        let events = [TsivaEvent.fixture("a"), TsivaEvent.fixture("b")]

        let result = await makeTransport(client: client).send(events)

        XCTAssertEqual(result, .success)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/events")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 7)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tsiva-Api-Key"), "project-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "tsiva-ios/\(TsivaSDK.version)")

        let body = try TsivaJSON.makeDecoder().decode(EventBatch.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body.events.map(\.name), ["a", "b"])
        XCTAssertEqual(body.sentAt, sentAt)
    }

    func testEndpointWithPathPrefix() throws {
        let transport = makeTransport(client: MockHTTPClient(), endpoint: "https://example.com/tsiva/")
        XCTAssertEqual(transport.eventsURL.absoluteString, "https://example.com/tsiva/v1/events")
    }

    func testNetworkErrorIsRetryable() async {
        let client = MockHTTPClient(error: URLError(.notConnectedToInternet))
        let result = await makeTransport(client: client).send([.fixture()])
        guard case .retryable = result else { return XCTFail("expected retryable, got \(result)") }
    }

    func testStatusClassification() {
        func classify(_ status: Int, headers: [String: String] = [:]) -> DeliveryResult {
            let response = HTTPURLResponse(
                url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: headers
            )!
            return NetworkTransport.classify(response)
        }

        XCTAssertEqual(classify(200), .success)
        XCTAssertEqual(classify(202), .success)
        XCTAssertEqual(classify(500), .retryable(reason: "HTTP 500", retryAfter: nil))
        XCTAssertEqual(classify(503), .retryable(reason: "HTTP 503", retryAfter: nil))
        XCTAssertEqual(classify(408), .retryable(reason: "HTTP 408", retryAfter: nil))
        XCTAssertEqual(classify(429, headers: ["Retry-After": "12"]), .retryable(reason: "HTTP 429", retryAfter: 12))
        XCTAssertEqual(classify(400), .rejected(reason: "HTTP 400"))
        XCTAssertEqual(classify(401), .rejected(reason: "HTTP 401"))
        XCTAssertEqual(classify(413), .rejected(reason: "HTTP 413"))
    }
}

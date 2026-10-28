import XCTest
@testable import Tsiva

final class TsivaConfigurationTests: XCTestCase {
    private let endpoint = URL(string: "https://api.example.com")!

    func testDefaults() {
        let configuration = TsivaConfiguration(apiKey: "key", endpoint: endpoint)
        XCTAssertEqual(configuration.flushAt, 20)
        XCTAssertEqual(configuration.flushInterval, 30)
        XCTAssertEqual(configuration.maxQueueSize, 1000)
        XCTAssertEqual(configuration.maxRetries, 3)
        XCTAssertEqual(configuration.logLevel, .error)
        XCTAssertTrue(configuration.flushOnBackground)
        XCTAssertEqual(configuration.redactedPropertyKeys, TsivaConfiguration.defaultRedactedPropertyKeys)
        XCTAssertNil(configuration.beforeSend)
    }

    func testValidatedClampsOutOfRangeValues() {
        let configuration = TsivaConfiguration(
            apiKey: "key",
            endpoint: endpoint,
            flushAt: 0,
            flushInterval: -5,
            maxQueueSize: 0,
            maxRetries: -1,
            requestTimeout: 0
        ).validated()

        XCTAssertEqual(configuration.flushAt, 1)
        XCTAssertEqual(configuration.flushInterval, 1)
        XCTAssertEqual(configuration.maxQueueSize, 1)
        XCTAssertEqual(configuration.maxRetries, 0)
        XCTAssertEqual(configuration.requestTimeout, 1)
    }

    func testValidatedCapsBatchSize() {
        let configuration = TsivaConfiguration(apiKey: "key", endpoint: endpoint, flushAt: 10_000).validated()
        XCTAssertEqual(configuration.flushAt, 100)
        XCTAssertGreaterThanOrEqual(configuration.maxQueueSize, configuration.flushAt)
    }

    func testLogLevelOrdering() {
        XCTAssertLessThan(TsivaLogLevel.none, .error)
        XCTAssertLessThan(TsivaLogLevel.error, .warning)
        XCTAssertLessThan(TsivaLogLevel.warning, .debug)
    }
}

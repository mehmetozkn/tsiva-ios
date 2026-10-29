import XCTest
@testable import Tsiva

final class TsivaTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Tsiva.reset()
    }

    override func tearDown() {
        Tsiva.reset()
        super.tearDown()
    }

    @discardableResult
    private func installClient(
        _ configuration: TsivaConfiguration = .test(),
        sender: MockSender = MockSender(),
        defaults: UserDefaults = makeTestDefaults()
    ) -> MockSender {
        Tsiva.install {
            TsivaClient(configuration: configuration, sender: sender, defaults: defaults, context: .fixture)
        }
        return sender
    }

    func testTrackBeforeConfigureIsIgnored() async {
        XCTAssertFalse(Tsiva.isConfigured)
        Tsiva.track("app_opened")
        await Tsiva.flush()
        XCTAssertNil(Tsiva.anonymousId)
    }

    func testConfigureRejectsInvalidInput() {
        Tsiva.configure(apiKey: "  ", endpoint: URL(string: "https://api.example.com")!)
        XCTAssertFalse(Tsiva.isConfigured)

        Tsiva.configure(apiKey: "key", endpoint: URL(string: "ftp://api.example.com")!)
        XCTAssertFalse(Tsiva.isConfigured)
    }

    func testConfigureWithValidInput() {
        Tsiva.configure(TsivaConfiguration(
            apiKey: "key",
            endpoint: URL(string: "https://api.example.com")!,
            logLevel: .none,
            crashReportingEnabled: false
        ))
        XCTAssertTrue(Tsiva.isConfigured)
        XCTAssertNotNil(Tsiva.anonymousId)
    }

    func testSecondConfigureIsIgnored() {
        let first = installClient()
        let installed = Tsiva.install {
            TsivaClient(configuration: .test(), sender: MockSender(), defaults: makeTestDefaults())
        }
        XCTAssertFalse(installed)

        Tsiva.track("still_first")
        let expectation = expectation(description: "flush")
        Task {
            await Tsiva.flush()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(first.sentEvents.map(\.name), ["still_first"])
    }

    func testTrackAndFlushDeliversEvent() async throws {
        let sender = installClient()

        Tsiva.track("checkout_started", properties: ["payment_method": "card", "password": "secret"])
        await Tsiva.flush()

        let event = try XCTUnwrap(sender.sentEvents.first)
        XCTAssertEqual(event.name, "checkout_started")
        XCTAssertEqual(event.properties, ["payment_method": "card"])
        XCTAssertEqual(event.anonymousId, Tsiva.anonymousId)
        XCTAssertEqual(event.context, .fixture)
        XCTAssertFalse(event.sessionId.isEmpty)
    }

    func testEventsKeepTrackingOrder() async {
        let sender = installClient(.test(flushAt: 7))

        for index in 0..<200 { Tsiva.track("e\(index)") }
        await Tsiva.flush()

        XCTAssertEqual(sender.sentEvents.map(\.name), (0..<200).map { "e\($0)" })
    }

    func testTrackingFromManyThreads() async {
        let sender = installClient(.test(flushAt: 100))

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            Tsiva.track("e\(index)")
        }
        await Tsiva.flush()

        XCTAssertEqual(Set(sender.sentEvents.map(\.name)).count, 500)
    }

    func testInvalidEventNameIsDropped() async {
        let sender = installClient()
        Tsiva.track("   ")
        await Tsiva.flush()
        XCTAssertTrue(sender.sentEvents.isEmpty)
    }

    func testBeforeSendCanModifyOrDropEvents() async {
        let configuration = TsivaConfiguration.test(beforeSend: { event in
            guard event.name != "debug_only" else { return nil }
            var event = event
            event.properties["environment"] = "test"
            return event
        })
        let sender = installClient(configuration)

        Tsiva.track("debug_only")
        Tsiva.track("purchase")
        await Tsiva.flush()

        XCTAssertEqual(sender.sentEvents.map(\.name), ["purchase"])
        XCTAssertEqual(sender.sentEvents.first?.properties["environment"], "test")
    }

    func testAnonymousIdIsPersistedAcrossClients() {
        let defaults = makeTestDefaults()
        let first = TsivaClient(configuration: .test(), sender: MockSender(), defaults: defaults, context: .fixture)
        let second = TsivaClient(configuration: .test(), sender: MockSender(), defaults: defaults, context: .fixture)
        defer {
            first.shutdown()
            second.shutdown()
        }

        XCTAssertEqual(first.anonymousId, second.anonymousId)
        XCTAssertNotEqual(first.sessionId, second.sessionId)
    }

    func testFlushAfterShutdownReturns() async {
        let client = TsivaClient(configuration: .test(), sender: MockSender(), defaults: makeTestDefaults())
        client.shutdown()
        await client.flush()
    }
}

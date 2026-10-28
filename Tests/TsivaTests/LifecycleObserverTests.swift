#if canImport(UIKit)
import UIKit
import XCTest
@testable import Tsiva

final class LifecycleObserverTests: XCTestCase {
    func testEnteringBackgroundFlushesQueuedEvents() async {
        var configuration = TsivaConfiguration.test()
        configuration.flushOnBackground = true
        let sender = MockSender()
        let client = TsivaClient(configuration: configuration, sender: sender, defaults: makeTestDefaults(), context: .fixture)
        defer { client.shutdown() }

        client.track("before_background", properties: [:])
        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        await waitUntil { sender.sentEvents.map(\.name) == ["before_background"] }
    }

    func testBackgroundFlushCanBeDisabled() async throws {
        let sender = MockSender()
        let client = TsivaClient(configuration: .test(), sender: sender, defaults: makeTestDefaults(), context: .fixture)
        defer { client.shutdown() }

        client.track("stays_queued", properties: [:])
        await MainActor.run {
            NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(sender.sentEvents.isEmpty)
    }
}
#endif

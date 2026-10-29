import XCTest
@testable import Tsiva

final class IdentityTests: XCTestCase {
    private func makeClient(defaults: UserDefaults, sender: MockSender = MockSender()) -> TsivaClient {
        TsivaClient(configuration: .test(), sender: sender, defaults: defaults, context: .fixture)
    }

    func testIdentifyAppliesToFollowingEvents() async {
        let sender = MockSender()
        let client = makeClient(defaults: makeTestDefaults(), sender: sender)
        defer { client.shutdown() }

        client.track("before", properties: [:])
        client.identify("  user-42 ")
        client.track("after", properties: [:])
        await client.flush()

        XCTAssertEqual(sender.sentEvents.map(\.name), ["before", "$identify", "after"])
        XCTAssertEqual(sender.sentEvents.map(\.userId), [nil, "user-42", "user-42"])
        XCTAssertEqual(client.userId, "user-42")
    }

    func testIdentifyWithTheSameIdSendsNothingNew() async {
        let sender = MockSender()
        let client = makeClient(defaults: makeTestDefaults(), sender: sender)
        defer { client.shutdown() }

        client.identify("user-42")
        client.identify("user-42")
        client.identify("user-43")
        await client.flush()

        XCTAssertEqual(sender.sentEvents.map(\.userId), ["user-42", "user-43"])
    }

    func testUserIdIsRememberedAcrossLaunches() {
        let defaults = makeTestDefaults()
        let first = makeClient(defaults: defaults)
        first.identify("user-42")
        first.shutdown()

        let second = makeClient(defaults: defaults)
        defer { second.shutdown() }
        XCTAssertEqual(second.userId, "user-42")
        XCTAssertEqual(second.anonymousId, first.anonymousId)
    }

    func testInvalidUserIdIsIgnored() {
        let client = makeClient(defaults: makeTestDefaults())
        defer { client.shutdown() }
        client.identify("user-1")
        client.identify("   ")
        client.identify(String(repeating: "x", count: UserID.maxLength + 1))
        XCTAssertEqual(client.userId, "user-1")
    }

    func testResetForgetsUserAndRotatesAnonymousId() async {
        let defaults = makeTestDefaults()
        let sender = MockSender()
        let client = makeClient(defaults: defaults, sender: sender)
        defer { client.shutdown() }
        client.identify("user-42")
        let before = client.anonymousId

        client.reset()
        client.track("logged_out_event", properties: [:])
        await client.flush()

        XCTAssertNil(client.userId)
        XCTAssertNotEqual(client.anonymousId, before)
        XCTAssertNil(sender.sentEvents.last?.userId)
        XCTAssertEqual(sender.sentEvents.last?.anonymousId, client.anonymousId)

        let relaunched = makeClient(defaults: defaults)
        defer { relaunched.shutdown() }
        XCTAssertNil(relaunched.userId)
        XCTAssertEqual(relaunched.anonymousId, client.anonymousId)
    }

    func testUserIdIsOmittedFromJSONUntilSet() throws {
        let anonymous = try TsivaJSON.makeEncoder().encode(TsivaEvent.fixture())
        XCTAssertFalse(String(decoding: anonymous, as: UTF8.self).contains("user_id"))

        let identified = TsivaEvent(name: "e", anonymousId: "a", sessionId: "s", userId: "user-42", context: .fixture)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: TsivaJSON.makeEncoder().encode(identified)) as? [String: Any])
        XCTAssertEqual(json["user_id"] as? String, "user-42")
    }

    func testCrashSessionFollowsIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tsiva-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = TsivaConfiguration.test()
        configuration.crashReportingEnabled = true
        let client = TsivaClient(
            configuration: configuration, sender: MockSender(), crashSender: MockCrashSender(),
            crashDirectory: directory, defaults: makeTestDefaults(), context: .fixture
        )
        defer { client.shutdown() }

        client.identify("user-42")

        let saved = try JSONDecoder().decode(CrashSession.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        XCTAssertEqual(saved.userId, "user-42")
        let raw = try XCTUnwrap(RawCrashReport.parse("tsiva-crash-v1\nkind=signal\nsignal=11\nframes\n0x1\nimages\nend"))
        XCTAssertEqual(CrashReport(raw: raw, session: saved).userId, "user-42")
    }

    func testFacadeIdentifyBeforeConfigureDoesNothing() {
        Tsiva.removeClient()
        Tsiva.identify(userId: "user-42")
        Tsiva.reset()
        XCTAssertNil(Tsiva.userId)
    }
}

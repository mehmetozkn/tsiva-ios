import XCTest
@testable import Tsiva

final class TsivaEventTests: XCTestCase {
    func testValueLiterals() {
        let properties: [String: TsivaValue] = ["s": "card", "i": 3, "d": 49.9, "b": true]
        XCTAssertEqual(properties["s"], .string("card"))
        XCTAssertEqual(properties["i"], .int(3))
        XCTAssertEqual(properties["d"], .double(49.9))
        XCTAssertEqual(properties["b"], .bool(true))
    }

    func testEncodesSnakeCaseKeysAndISODates() throws {
        let event = TsivaEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "checkout_started",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000.125),
            properties: ["payment_method": "card"],
            anonymousId: "anon-1",
            sessionId: "session-1",
            context: .fixture
        )

        let data = try TsivaJSON.makeEncoder().encode(event)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["id"] as? String, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(json["name"] as? String, "checkout_started")
        XCTAssertEqual(json["timestamp"] as? String, "2027-01-15T08:00:00.125Z")
        XCTAssertEqual(json["anonymous_id"] as? String, "anon-1")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertEqual((json["properties"] as? [String: Any])?["payment_method"] as? String, "card")

        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual((context["app"] as? [String: Any])?["bundle_id"] as? String, "com.example.app")
        XCTAssertEqual((context["sdk"] as? [String: Any])?["version"] as? String, TsivaSDK.version)
        XCTAssertEqual((context["device"] as? [String: Any])?["model"] as? String, "iPhone16,2")
    }

    func testRoundTrip() throws {
        let event = TsivaEvent.fixture("app_opened", properties: ["s": "x", "i": 1, "d": 1.5, "b": false])
        let data = try TsivaJSON.makeEncoder().encode(event)
        let decoded = try TsivaJSON.makeDecoder().decode(TsivaEvent.self, from: data)

        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.properties, event.properties)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, event.timestamp.timeIntervalSince1970, accuracy: 0.001)
    }

    func testNonFiniteDoubleEncodesAsZero() throws {
        let data = try TsivaJSON.makeEncoder().encode(["v": TsivaValue.double(.infinity)])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"v":0}"#)
    }

    func testCurrentContextIsPopulated() {
        let context = TsivaContext.current()
        XCTAssertEqual(context.sdk.name, "tsiva-ios")
        XCTAssertFalse(context.os.version.isEmpty)
        XCTAssertFalse(context.device.model.isEmpty)
        XCTAssertFalse(context.timezone.isEmpty)
    }
}

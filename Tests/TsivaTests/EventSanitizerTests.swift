import XCTest
@testable import Tsiva

final class EventSanitizerTests: XCTestCase {
    private let sanitizer = EventSanitizer(redactedKeys: TsivaConfiguration.defaultRedactedPropertyKeys)

    func testNameIsTrimmed() {
        XCTAssertEqual(sanitizer.sanitizeName("  app_opened \n"), "app_opened")
    }

    func testEmptyOrTooLongNameIsRejected() {
        XCTAssertNil(sanitizer.sanitizeName(""))
        XCTAssertNil(sanitizer.sanitizeName("   "))
        XCTAssertNil(sanitizer.sanitizeName(String(repeating: "a", count: EventSanitizer.maxNameLength + 1)))
        XCTAssertNotNil(sanitizer.sanitizeName(String(repeating: "a", count: EventSanitizer.maxNameLength)))
    }

    func testSensitiveKeysAreRemoved() {
        let result = sanitizer.sanitizeProperties([
            "password": "hunter2",
            "Refresh-Token": "abc",
            "user_email": "a@b.com",
            "Card Number": "4111",
            "apiKey": "k",
            "payment_method": "card"
        ])
        XCTAssertEqual(result, ["payment_method": "card"])
    }

    func testCustomRedactedKeys() {
        let sanitizer = EventSanitizer(redactedKeys: ["national_id"])
        XCTAssertTrue(sanitizer.isRedacted("NationalID"))
        XCTAssertFalse(sanitizer.isRedacted("password"))
    }

    func testLongValuesAndKeysAreTruncated() {
        let longKey = String(repeating: "k", count: 200)
        let result = sanitizer.sanitizeProperties([
            "note": .string(String(repeating: "x", count: 5000)),
            longKey: 1
        ])
        guard case .string(let note) = result["note"] else { return XCTFail("missing note") }
        XCTAssertEqual(note.count, EventSanitizer.maxStringLength)
        XCTAssertNotNil(result[String(repeating: "k", count: EventSanitizer.maxKeyLength)])
    }

    func testEmptyKeysAreRemovedAndCountIsCapped() {
        var properties: [String: TsivaValue] = ["  ": 1]
        for index in 0..<150 { properties["key_\(index)"] = .int(index) }
        let result = sanitizer.sanitizeProperties(properties)
        XCTAssertEqual(result.count, EventSanitizer.maxPropertyCount)
        XCTAssertNil(result[""])
    }
}

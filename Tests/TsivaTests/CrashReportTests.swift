import Foundation
import TsivaCrashHandler
import XCTest
@testable import Tsiva

final class CrashReportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tsiva-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let session = CrashSession(anonymousId: "anon-old", sessionId: "session-old", context: .fixture, executableName: "MyApp")

    private let sampleSignal = """
    tsiva-crash-v1
    kind=signal
    timestamp=1800000000
    signal=11
    code=1
    fault_address=0x0
    frames
    0x100004010
    0x100008020
    0x1a0001000
    0xdeadbeef
    images
    0x100000000 0x10000 11111111-2222-3333-4444-555555555555 /private/var/containers/Bundle/Application/X/MyApp.app/MyApp
    0x1a0000000 0x80000 aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee /usr/lib/system/libsystem_c.dylib
    0x1b0000000 0x1000 - /usr/lib/unused.dylib
    end
    """

    func testParseSignalReport() throws {
        let raw = try XCTUnwrap(RawCrashReport.parse(sampleSignal))
        XCTAssertEqual(raw.kind, "signal")
        XCTAssertEqual(raw.signal, 11)
        XCTAssertEqual(raw.code, 1)
        XCTAssertEqual(raw.timestamp, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(raw.frames, [0x1_0000_4010, 0x1_0000_8020, 0x1_a000_1000, 0xdead_beef])
        XCTAssertEqual(raw.images.count, 3)
        XCTAssertNil(raw.images[2].uuid)
    }

    func testParseRejectsOtherFiles() {
        XCTAssertNil(RawCrashReport.parse(""))
        XCTAssertNil(RawCrashReport.parse("hello"))
        XCTAssertNil(RawCrashReport.parse("tsiva-crash-v1\nkind=unknown\nend"))
    }

    func testParseTruncatedReportKeepsWhatWasWritten() throws {
        let truncated = "tsiva-crash-v1\nkind=signal\nsignal=6\nframes\n0x100004010\n0x1000"
        let raw = try XCTUnwrap(RawCrashReport.parse(truncated))
        XCTAssertEqual(raw.frames, [0x1_0000_4010, 0x1000])
        XCTAssertTrue(raw.images.isEmpty)
    }

    func testBuildReportMapsFramesToImages() throws {
        let report = CrashReport(raw: try XCTUnwrap(RawCrashReport.parse(sampleSignal)), session: session)

        XCTAssertEqual(report.kind, "signal")
        XCTAssertEqual(report.signal, .init(number: 11, name: "SIGSEGV", code: 1, faultAddress: "0x0"))
        XCTAssertNil(report.exception)
        XCTAssertEqual(report.anonymousId, "anon-old")
        XCTAssertEqual(report.sessionId, "session-old")
        XCTAssertEqual(report.frames, [
            .init(address: "0x100004010", image: "MyApp", offset: 0x4010, inApp: true),
            .init(address: "0x100008020", image: "MyApp", offset: 0x8020, inApp: true),
            .init(address: "0x1a0001000", image: "libsystem_c.dylib", offset: 0x1000, inApp: false),
            .init(address: "0xdeadbeef", image: nil, offset: nil, inApp: false),
        ])
        // Only binaries that appear in the stack are kept.
        XCTAssertEqual(report.images.map(\.name), ["MyApp", "libsystem_c.dylib"])
        XCTAssertEqual(report.images[0].uuid, "11111111-2222-3333-4444-555555555555")
    }

    func testReportJSONUsesSnakeCase() throws {
        let report = CrashReport(raw: try XCTUnwrap(RawCrashReport.parse(sampleSignal)), session: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: TsivaJSON.makeEncoder().encode(report)) as? [String: Any])
        XCTAssertNotNil(json["anonymous_id"])
        XCTAssertEqual((json["signal"] as? [String: Any])?["fault_address"] as? String, "0x0")
        XCTAssertEqual(((json["frames"] as? [[String: Any]])?.first)?["in_app"] as? Bool, true)
        XCTAssertEqual(((json["images"] as? [[String: Any]])?.first)?["load_address"] as? String, "0x100000000")
    }

    func testCHandlerWritesParseableSignalReport() throws {
        let path = directory.appendingPathComponent("crash.txt").path
        XCTAssertEqual(tsiva_crash_install(path), 0)
        defer { tsiva_crash_uninstall() }

        XCTAssertEqual(tsiva_crash_write_signal_report_for_testing(SIGBUS), 0)
        let raw = try XCTUnwrap(RawCrashReport.parse(String(contentsOfFile: path, encoding: .utf8)))

        XCTAssertEqual(raw.kind, "signal")
        XCTAssertEqual(raw.signal, Int(SIGBUS))
        XCTAssertFalse(raw.frames.isEmpty)
        XCTAssertTrue(raw.images.contains { $0.uuid != nil && $0.size > 0 }, "loaded binaries with UUIDs are listed")

        // Frames of the current stack resolve to loaded binaries.
        let report = CrashReport(raw: raw, session: session)
        XCTAssertTrue(report.frames.contains { $0.image != nil })
    }

    func testCHandlerWritesExceptionReportOnlyOnce() throws {
        let path = directory.appendingPathComponent("crash.txt").path
        XCTAssertEqual(tsiva_crash_install(path), 0)
        defer { tsiva_crash_uninstall() }

        let frames: [UInt] = [0x1000, 0x2000]
        let written = frames.withUnsafeBufferPointer {
            tsiva_crash_write_exception_report("NSRangeException", "index 5 beyond bounds\nline two \\ done", $0.baseAddress, 2)
        }
        XCTAssertEqual(written, 0)
        let again = frames.withUnsafeBufferPointer {
            tsiva_crash_write_exception_report("Second", "", $0.baseAddress, 2)
        }
        XCTAssertEqual(again, -1, "the SIGABRT after an exception must not produce a second report")

        let raw = try XCTUnwrap(RawCrashReport.parse(String(contentsOfFile: path, encoding: .utf8)))
        XCTAssertEqual(raw.kind, "exception")
        XCTAssertEqual(raw.exceptionName, "NSRangeException")
        XCTAssertEqual(raw.exceptionReason, "index 5 beyond bounds\nline two \\ done")
        XCTAssertEqual(raw.frames, [0x1000, 0x2000])
    }
}

final class CrashReporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tsiva-reporter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("pending"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        tsiva_crash_uninstall()
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePreviousLaunch(anonymousId: String = "anon-old") throws {
        let session = CrashSession(anonymousId: anonymousId, sessionId: "session-old", context: .fixture, executableName: "MyApp")
        try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"))
        try "tsiva-crash-v1\nkind=signal\ntimestamp=1800000000\nsignal=6\nframes\n0x1000\nimages\nend\n"
            .write(to: directory.appendingPathComponent("crash.txt"), atomically: true, encoding: .utf8)
    }

    func testPreviousCrashBecomesPendingReport() throws {
        try writePreviousLaunch()
        let reporter = CrashReporter(directory: directory, logger: TsivaLogger(level: .none))

        reporter.collectPreviousCrash()

        let pending = reporter.pendingReports()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.report.anonymousId, "anon-old")
        XCTAssertEqual(pending.first?.report.signal?.name, "SIGABRT")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reporter.reportURL.path))
    }

    func testCrashWithoutSessionIsDiscarded() throws {
        try writePreviousLaunch()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("session.json"))
        let reporter = CrashReporter(directory: directory, logger: TsivaLogger(level: .none))

        reporter.collectPreviousCrash()

        XCTAssertTrue(reporter.pendingReports().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reporter.reportURL.path))
    }

    func testSendPendingDeletesDeliveredAndRejectedReports() async throws {
        let reporter = CrashReporter(directory: directory, logger: TsivaLogger(level: .none))
        for _ in 0..<3 {
            try writePreviousLaunch()
            reporter.collectPreviousCrash()
        }
        XCTAssertEqual(reporter.pendingReports().count, 3)

        let sender = MockCrashSender(results: [.success, .rejected(reason: "HTTP 400"), .retryable(reason: "offline", retryAfter: nil)])
        await reporter.sendPending(using: sender)

        XCTAssertEqual(sender.reports.count, 3)
        XCTAssertEqual(reporter.pendingReports().count, 1, "the report that failed temporarily is kept")

        await reporter.sendPending(using: MockCrashSender())
        XCTAssertTrue(reporter.pendingReports().isEmpty)
    }

    func testStartRecordsSessionAndArmsHandlers() throws {
        try writePreviousLaunch(anonymousId: "anon-previous")
        let reporter = CrashReporter(directory: directory, logger: TsivaLogger(level: .none))
        let current = CrashSession(anonymousId: "anon-now", sessionId: "session-now", context: .fixture, executableName: "MyApp")

        reporter.start(session: current)

        XCTAssertEqual(reporter.pendingReports().first?.report.anonymousId, "anon-previous")
        let saved = try JSONDecoder().decode(CrashSession.self, from: Data(contentsOf: reporter.sessionURL))
        XCTAssertEqual(saved, current)
    }

    func testClientSendsCrashFromPreviousLaunch() async throws {
        try writePreviousLaunch()
        let sender = MockCrashSender()
        var configuration = TsivaConfiguration.test()
        configuration.crashReportingEnabled = true

        let client = TsivaClient(
            configuration: configuration,
            sender: MockSender(),
            crashSender: sender,
            crashDirectory: directory,
            defaults: makeTestDefaults(),
            context: .fixture
        )
        defer { client.shutdown() }

        await waitUntil { sender.reports.count == 1 }
        XCTAssertEqual(sender.reports.first?.sessionId, "session-old")
        XCTAssertNotEqual(sender.reports.first?.sessionId, client.sessionId)
    }

    func testTransportPostsCrashReports() async throws {
        let client = MockHTTPClient()
        let transport = NetworkTransport(apiKey: "key", endpoint: URL(string: "https://api.example.com")!, timeout: 5, client: client)
        try writePreviousLaunch()
        let reporter = CrashReporter(directory: directory, logger: TsivaLogger(level: .none))
        reporter.collectPreviousCrash()
        let report = try XCTUnwrap(reporter.pendingReports().first?.report)

        let result = await transport.sendCrash(report)

        XCTAssertEqual(result, .success)
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/crashes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tsiva-Api-Key"), "key")
        let body = try TsivaJSON.makeDecoder().decode(CrashReport.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(body, report)
    }
}

final class MockCrashSender: CrashSender {
    private let state = Locked<(results: [DeliveryResult], reports: [CrashReport])>(([], []))

    init(results: [DeliveryResult] = []) {
        state.withLock { $0.results = results }
    }

    var reports: [CrashReport] { state.withLock { $0.reports } }

    func sendCrash(_ report: CrashReport) async -> DeliveryResult {
        state.withLock { state in
            state.reports.append(report)
            return state.results.isEmpty ? .success : state.results.removeFirst()
        }
    }
}

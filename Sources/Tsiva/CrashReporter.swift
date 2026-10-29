import Foundation
import TsivaCrashHandler

/// Captures crashes and delivers them on the next launch.
///
/// Files in the reporter's directory:
/// - `crash.txt`: written by the signal or exception handler at the moment of a crash.
/// - `session.json`: the current session, needed to attribute a crash after the app restarts.
/// - `pending/<id>.json`: reports waiting to be sent; removed once the server accepted or rejected them.
final class CrashReporter: Sendable {
    let directory: URL
    private let logger: TsivaLogger

    init(directory: URL, logger: TsivaLogger) {
        self.directory = directory
        self.logger = logger
    }

    var reportURL: URL { directory.appendingPathComponent("crash.txt") }
    var sessionURL: URL { directory.appendingPathComponent("session.json") }
    var pendingDirectory: URL { directory.appendingPathComponent("pending", isDirectory: true) }

    /// The default location: Application Support/Tsiva/<bundle id>.
    static func defaultDirectory() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support
            .appendingPathComponent("Tsiva", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "default", isDirectory: true)
    }

    /// Turns a crash from the previous launch into a pending report, records the new session and arms the
    /// handlers. Call once per launch.
    func start(session: CrashSession) {
        do {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Crash reporting disabled: could not create \(directory.path)")
            return
        }

        collectPreviousCrash()

        do {
            try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic)
        } catch {
            logger.error("Crash reporting disabled: could not save the session")
            return
        }

        guard tsiva_crash_install(reportURL.path) == 0 else {
            logger.error("Crash reporting disabled: could not install signal handlers")
            return
        }
        installExceptionHandler()
        logger.debug("Crash reporting enabled")
    }

    /// Moves `crash.txt` from the previous launch into `pending/`, attributed to that launch's session.
    func collectPreviousCrash() {
        defer { try? FileManager.default.removeItem(at: reportURL) }
        guard let text = try? String(contentsOf: reportURL, encoding: .utf8) else { return }
        guard let raw = RawCrashReport.parse(text) else {
            logger.warning("Ignored an unreadable crash report")
            return
        }
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(CrashSession.self, from: data) else {
            logger.warning("Ignored a crash report without session information")
            return
        }

        let report = CrashReport(raw: raw, session: session)
        do {
            let encoded = try TsivaJSON.makeEncoder().encode(report)
            try encoded.write(to: pendingDirectory.appendingPathComponent("\(report.id.uuidString).json"), options: .atomic)
            logger.debug("Found a crash from the previous launch")
        } catch {
            logger.error("Could not save the crash report: \(error.localizedDescription)")
        }
    }

    func pendingReports() -> [(url: URL, report: CrashReport)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let report = try? TsivaJSON.makeDecoder().decode(CrashReport.self, from: data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return (url, report)
            }
            .sorted { $0.report.timestamp < $1.report.timestamp }
    }

    /// Sends pending reports. Delivered and rejected reports are deleted; on a retryable failure the rest
    /// waits for the next launch.
    func sendPending(using sender: CrashSender) async {
        for (url, report) in pendingReports() {
            switch await sender.sendCrash(report) {
            case .success:
                try? FileManager.default.removeItem(at: url)
                logger.debug("Sent crash report \(report.id.uuidString)")
            case .rejected(let reason):
                try? FileManager.default.removeItem(at: url)
                logger.error("Dropped crash report rejected by the server: \(reason)")
            case .retryable(let reason, _):
                logger.warning("Crash report upload failed (\(reason)); will retry on next launch")
                return
            }
        }
    }

    private func installExceptionHandler() {
        CrashReporter.previousExceptionHandler.withLock { previous in
            if previous == nil {
                previous = .some(NSGetUncaughtExceptionHandler())
            }
        }
        NSSetUncaughtExceptionHandler(tsivaHandleUncaughtException)
    }

    /// The handler that was installed before ours; called after our report is written. The outer optional
    /// tracks whether it has been captured yet.
    static let previousExceptionHandler = Locked<NSUncaughtExceptionHandler??>(nil)
}

/// Delivers crash reports. NetworkTransport implements it; tests use a mock.
protocol CrashSender: Sendable {
    func sendCrash(_ report: CrashReport) async -> DeliveryResult
}

private func tsivaHandleUncaughtException(_ exception: NSException) {
    let frames = exception.callStackReturnAddresses.map { UInt($0.uintValue) }
    frames.withUnsafeBufferPointer { buffer in
        _ = tsiva_crash_write_exception_report(
            exception.name.rawValue,
            exception.reason ?? "",
            buffer.baseAddress,
            Int32(buffer.count)
        )
    }
    if case .some(.some(let previous)) = CrashReporter.previousExceptionHandler.withLock({ $0 }) {
        previous(exception)
    }
}

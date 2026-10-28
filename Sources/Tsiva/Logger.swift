import os

/// Thin wrapper over `os.Logger` that respects the configured `TsivaLogLevel`.
struct TsivaLogger: Sendable {
    let level: TsivaLogLevel
    private let logger = Logger(subsystem: "com.tsiva.sdk", category: "Tsiva")

    init(level: TsivaLogLevel) {
        self.level = level
    }

    func error(_ message: @autoclosure () -> String) {
        guard level >= .error else { return }
        let text = message()
        logger.error("[Tsiva] \(text, privacy: .public)")
    }

    func warning(_ message: @autoclosure () -> String) {
        guard level >= .warning else { return }
        let text = message()
        logger.warning("[Tsiva] \(text, privacy: .public)")
    }

    func debug(_ message: @autoclosure () -> String) {
        guard level >= .debug else { return }
        let text = message()
        logger.debug("[Tsiva] \(text, privacy: .public)")
    }
}

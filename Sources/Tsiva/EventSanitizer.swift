import Foundation

/// Validates event names and strips sensitive or oversized property data before an event is queued.
struct EventSanitizer: Sendable {
    static let maxNameLength = 128
    static let maxPropertyCount = 100
    static let maxKeyLength = 128
    static let maxStringLength = 1024

    private let redactedKeys: [String]

    init(redactedKeys: Set<String>) {
        self.redactedKeys = redactedKeys.map(Self.normalize).filter { !$0.isEmpty }
    }

    /// Returns the cleaned event name, or `nil` if the name is unusable.
    func sanitizeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxNameLength else { return nil }
        return trimmed
    }

    /// Removes redacted and empty keys, truncates long keys and strings, and caps the property count.
    func sanitizeProperties(_ properties: [String: TsivaValue]) -> [String: TsivaValue] {
        var result: [String: TsivaValue] = [:]
        // Sorted so the same input always keeps the same properties when the count is capped.
        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            guard result.count < Self.maxPropertyCount else { break }

            let key = String(key.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxKeyLength))
            guard !key.isEmpty, !isRedacted(key) else { continue }

            if case .string(let string) = value, string.count > Self.maxStringLength {
                result[key] = .string(String(string.prefix(Self.maxStringLength)))
            } else {
                result[key] = value
            }
        }
        return result
    }

    func isRedacted(_ key: String) -> Bool {
        let normalized = Self.normalize(key)
        return redactedKeys.contains { normalized.contains($0) }
    }

    private static func normalize(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }
}

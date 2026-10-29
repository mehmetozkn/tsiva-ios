import Foundation

/// A crash report as sent to `POST /v1/crashes`.
struct CrashReport: Codable, Equatable, Sendable {
    struct Signal: Codable, Equatable, Sendable {
        var number: Int
        var name: String
        var code: Int
        var faultAddress: String

        enum CodingKeys: String, CodingKey {
            case number, name, code
            case faultAddress = "fault_address"
        }
    }

    struct Exception: Codable, Equatable, Sendable {
        var name: String
        var reason: String
    }

    struct Frame: Codable, Equatable, Sendable {
        var address: String
        /// File name of the binary containing the address, if known.
        var image: String?
        /// Address relative to the binary's load address; together with the binary's UUID this is what
        /// symbolication tools such as `atos` need.
        var offset: UInt64?
        var inApp: Bool

        enum CodingKeys: String, CodingKey {
            case address, image, offset
            case inApp = "in_app"
        }
    }

    struct Image: Codable, Equatable, Sendable {
        var name: String
        var uuid: String?
        var loadAddress: String
        var size: UInt64

        enum CodingKeys: String, CodingKey {
            case name, uuid, size
            case loadAddress = "load_address"
        }
    }

    var id: UUID
    var timestamp: Date
    /// "signal" or "exception".
    var kind: String
    var signal: Signal?
    var exception: Exception?
    var frames: [Frame]
    /// Only the binaries that appear in `frames`.
    var images: [Image]
    var anonymousId: String
    var sessionId: String
    var userId: String?
    var context: TsivaContext

    enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, signal, exception, frames, images, context
        case anonymousId = "anonymous_id"
        case sessionId = "session_id"
        case userId = "user_id"
    }
}

/// The session a crash happened in. Saved at launch, because the report is only sent on the next launch.
struct CrashSession: Codable, Equatable, Sendable {
    var anonymousId: String
    var sessionId: String
    var userId: String? = nil
    var context: TsivaContext
    /// File name of the app's executable, used to mark frames as in-app.
    var executableName: String
}

/// The report file written by the crash handler, before it is matched with its session.
struct RawCrashReport: Equatable {
    struct Image: Equatable {
        var loadAddress: UInt64
        var size: UInt64
        var uuid: String?
        var path: String
    }

    var kind: String
    var timestamp: Date
    var signal: Int?
    var code: Int?
    var faultAddress: UInt64?
    var exceptionName: String?
    var exceptionReason: String?
    var frames: [UInt64]
    var images: [Image]

    static let header = "tsiva-crash-v1"

    /// Parses the handler's text format. Returns nil for files that are not crash reports. A report cut off
    /// while being written still parses, with the frames and images written so far.
    static func parse(_ text: String) -> RawCrashReport? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next() == Substring(header) else { return nil }

        var fields: [String: String] = [:]
        var frames: [UInt64] = []
        var images: [Image] = []
        var section = "fields"

        while let line = lines.next() {
            switch line {
            case "frames": section = "frames"; continue
            case "images": section = "images"; continue
            case "end": section = "end"
            default: break
            }
            if section == "end" { break }

            switch section {
            case "fields":
                guard let separator = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<separator])] = String(line[line.index(after: separator)...])
            case "frames":
                if let address = parseHex(line) { frames.append(address) }
            case "images":
                let parts = line.split(separator: " ", maxSplits: 3)
                guard parts.count == 4, let load = parseHex(parts[0]), let size = parseHex(parts[1]) else { continue }
                images.append(Image(loadAddress: load, size: size, uuid: parts[2] == "-" ? nil : String(parts[2]), path: String(parts[3])))
            default:
                break
            }
        }

        guard let kind = fields["kind"], kind == "signal" || kind == "exception" else { return nil }
        return RawCrashReport(
            kind: kind,
            timestamp: fields["timestamp"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) ?? Date(),
            signal: fields["signal"].flatMap { Int($0) },
            code: fields["code"].flatMap { Int($0) },
            faultAddress: fields["fault_address"].flatMap { parseHex(Substring($0)) },
            exceptionName: fields["exception_name"].map(unescape),
            exceptionReason: fields["exception_reason"].map(unescape),
            frames: frames,
            images: images
        )
    }

    private static func parseHex(_ text: Substring) -> UInt64? {
        guard text.hasPrefix("0x") else { return nil }
        return UInt64(text.dropFirst(2), radix: 16)
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

extension CrashReport {
    static let maxFrames = 100
    static let maxReasonLength = 1024

    /// Combines a raw report with the session it happened in and maps addresses to binaries.
    init(raw: RawCrashReport, session: CrashSession, id: UUID = UUID()) {
        var frames: [Frame] = []
        var usedImages: [String: Image] = [:]

        for address in raw.frames.prefix(Self.maxFrames) {
            let hex = "0x" + String(address, radix: 16)
            guard let image = raw.images.first(where: { address >= $0.loadAddress && address < $0.loadAddress + $0.size }) else {
                frames.append(Frame(address: hex, image: nil, offset: nil, inApp: false))
                continue
            }
            let name = (image.path as NSString).lastPathComponent
            frames.append(Frame(address: hex, image: name, offset: address - image.loadAddress, inApp: name == session.executableName))
            usedImages[image.path] = Image(
                name: name,
                uuid: image.uuid,
                loadAddress: "0x" + String(image.loadAddress, radix: 16),
                size: image.size
            )
        }

        self.init(
            id: id,
            timestamp: raw.timestamp,
            kind: raw.kind,
            signal: raw.signal.map { number in
                Signal(
                    number: number,
                    name: Self.signalName(number),
                    code: raw.code ?? 0,
                    faultAddress: "0x" + String(raw.faultAddress ?? 0, radix: 16)
                )
            },
            exception: raw.exceptionName.map { name in
                Exception(name: name, reason: String((raw.exceptionReason ?? "").prefix(Self.maxReasonLength)))
            },
            frames: frames,
            images: usedImages.values.sorted { $0.loadAddress < $1.loadAddress },
            anonymousId: session.anonymousId,
            sessionId: session.sessionId,
            userId: session.userId,
            context: session.context
        )
    }

    static func signalName(_ number: Int) -> String {
        switch Int32(number) {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(number)"
        }
    }
}

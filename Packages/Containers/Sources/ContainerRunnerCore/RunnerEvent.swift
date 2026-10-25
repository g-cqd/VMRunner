public import Foundation

/// A line the runner writes to standard output in `--json` mode: one JSON object per line, in the order things happened.
///
/// `time` is seconds on the monotonic clock since the runner started, so a phase can also be read as the difference
/// between two events and does not depend on the launcher's clock.
public struct RunnerEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// One step of the run finished; `name` says which (`kernel`, `init-image`, `pull`, `create`, `boot`, `run`) and
        /// `seconds` how long it took.
        case phase
        /// A chunk of what the container wrote; `stream` says where and `text` is the chunk, decoded leniently.
        case output
        /// The container's process ended; `status` is its exit status.
        case exited
        /// Something failed around the container; `message` says what.
        case error
        /// The last line: `status` is the runner's own exit status.
        case finished
    }

    /// Which output stream of the container a chunk came from.
    public enum Stream: String, Codable, Sendable {
        case stdout
        case stderr
    }

    /// The most bytes one `output` event carries; a longer write is split.
    public static let maximumChunkBytes = 16384

    public var event: Kind
    public var time: Double
    public var name: String?
    public var seconds: Double?
    public var stream: Stream?
    public var text: String?
    public var status: Int32?
    public var message: String?

    public init(
        _ event: Kind, time: Double = 0, name: String? = nil, seconds: Double? = nil, stream: Stream? = nil, text: String? = nil,
        status: Int32? = nil, message: String? = nil
    ) {
        self.event = event
        self.time = time
        self.name = name
        self.seconds = seconds
        self.stream = stream
        self.text = text
        self.status = status
        self.message = message
    }

    /// The JSON object as one line, without the newline.
    public func line() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(self)
        guard let line = String(bytes: encoded, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "an event is not valid UTF-8"))
        }
        return line
    }

    /// `duration` as fractional seconds.
    public static func seconds(of duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// `data` cut into pieces of at most ``maximumChunkBytes`` bytes, in order. Empty data gives no piece.
    public static func chunks(of data: Data) -> [Data] {
        stride(from: 0, to: data.count, by: maximumChunkBytes).map { offset in
            let start = data.startIndex + offset
            return data.subdata(in: start..<min(start + maximumChunkBytes, data.endIndex))
        }
    }
}

/// Finds the `stop` line the launcher writes to the runner's standard input, in whatever pieces the bytes arrive.
public struct StopLineDetector: Sendable {
    /// A line longer than this cannot be `stop`; it is dropped instead of kept, so the buffer stays small.
    static let maximumLineBytes = 64

    private var pending = Data()
    /// Whether the rest of the current line is being skipped because it was too long.
    private var skipping = false

    public init() {}

    /// Adds `data` and tells whether a complete line of it was `stop` (a trailing carriage return and spaces are ignored).
    public mutating func feed(_ data: Data) -> Bool {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[pending.startIndex..<newline]
            let text = String(bytes: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isStop = !skipping && text == "stop"
            skipping = false
            pending = Data(pending[(newline + 1)...])
            if isStop { return true }
        }
        if pending.count > Self.maximumLineBytes {
            pending = Data()
            skipping = true
        }
        return false
    }
}

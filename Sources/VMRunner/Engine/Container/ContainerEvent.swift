import Foundation

/// Which output stream of the container a chunk came from.
enum ContainerStream: String, Sendable {
    case stdout, stderr
}

/// One line the runner wrote to its standard output in `--json` mode, decoded. A line of an unknown kind, a line that is not a
/// JSON object, and a line that lacks what its kind needs decode to nothing: a newer runner may say more than this app knows.
enum ContainerEvent: Equatable, Sendable {
    case phase(name: String, seconds: Double)
    case output(stream: ContainerStream, text: String)
    case exited(status: Int32)
    case error(message: String)
    case finished(status: Int32)

    /// The fields of a line; each kind uses some of them.
    private struct Wire: Decodable {
        var event: String
        var name: String?
        var seconds: Double?
        var stream: String?
        var text: String?
        var status: Int32?
        var message: String?
    }

    private static let decoder = JSONDecoder()

    /// The event in `line` (without its newline), or nil.
    init?(line: some Collection<UInt8>) {
        guard let wire = try? Self.decoder.decode(Wire.self, from: Data(line)) else { return nil }
        switch wire.event {
        case "phase":
            guard let name = wire.name else { return nil }
            self = .phase(name: name, seconds: wire.seconds ?? 0)
        case "output":
            guard let stream = wire.stream.flatMap(ContainerStream.init(rawValue:)), let text = wire.text else { return nil }
            self = .output(stream: stream, text: text)
        case "exited":
            guard let status = wire.status else { return nil }
            self = .exited(status: status)
        case "error":
            guard let message = wire.message else { return nil }
            self = .error(message: message)
        case "finished":
            guard let status = wire.status else { return nil }
            self = .finished(status: status)
        default:
            return nil
        }
    }
}

/// Cuts the bytes the runner writes into lines, whatever the size of the reads: a line held back until its newline arrives
/// may span reads. A line longer than `maxLineBytes` is dropped whole (up to its newline) and counted, so the buffer stays
/// small whatever the runner writes. The runner's longest legitimate line is an `output` event of 16384 bytes of control
/// characters, each escaped to six, which is under 100 KiB; the default bound leaves room for that.
struct RunnerLineSplitter: Sendable {
    static let defaultMaxLineBytes = 256 * 1024

    let maxLineBytes: Int
    /// How many lines were dropped for their length.
    private(set) var droppedLines = 0
    private var pending: [UInt8] = []
    /// Whether the rest of the current line is skipped because it was too long.
    private var skipping = false

    init(maxLineBytes: Int = Self.defaultMaxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// The complete lines the chunk finishes, without their newlines and in order; empty lines are skipped.
    mutating func append(_ chunk: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = chunk.startIndex
        while let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
            take(chunk[start..<newline])
            endLine(into: &lines)
            start = newline + 1
        }
        take(chunk[start...])
        return lines
    }

    /// The end of the stream: the last line, when it had no newline.
    mutating func finish() -> [[UInt8]] {
        var lines: [[UInt8]] = []
        endLine(into: &lines)
        return lines
    }

    private mutating func take(_ segment: ArraySlice<UInt8>) {
        guard !skipping, !segment.isEmpty else { return }
        guard pending.count + segment.count <= maxLineBytes else {
            droppedLines += 1
            skipping = true
            pending = []
            return
        }
        pending += segment
    }

    private mutating func endLine(into lines: inout [[UInt8]]) {
        if !skipping, !pending.isEmpty { lines.append(pending) }
        pending = []
        skipping = false
    }
}

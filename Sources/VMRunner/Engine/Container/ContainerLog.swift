import GuestConsole
import Observation

/// Text kept to a size: when an append passes the limit the oldest bytes go, at a character boundary, and the count of what
/// went is kept. A quarter of the limit goes beyond the excess, so a text that is full is copied once per quarter of the limit
/// that was appended, not on every append.
struct BoundedText: Equatable, Sendable {
    let limit: Int
    private(set) var text = ""
    private(set) var droppedBytes = 0

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// The text, led by a line that says how much of the start was dropped.
    var markedText: String {
        droppedBytes > 0 ? "[dropped \(droppedBytes) bytes]\n" + text : text
    }

    mutating func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        text += String(decoding: bytes, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
        guard text.utf8.count > limit else { return }
        let kept = Array(text.utf8)
        var cut = kept.count - limit + limit / 4
        while cut < kept.count, kept[cut] & 0xC0 == 0x80 { cut += 1 }
        droppedBytes += cut
        text = String(decoding: kept[cut...], as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
    }
}

/// Removes every escape sequence that is left after the console filter, colour and cursor controls included: the log is plain
/// text and shows none of them. A sequence cut between two calls is removed whole, because the state is kept from one call to
/// the next (one stripper per output stream, as the console filter has).
struct EscapeSequenceStripper: Sendable {
    private enum State: Sendable { case text, escape, csi }
    private var state = State.text

    mutating func pass(_ bytes: [UInt8]) -> [UInt8] {
        let escape = UInt8(ascii: "\u{1B}")
        let open = UInt8(ascii: "[")
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        for byte in bytes {
            // A line feed or a tab is text whatever state the sequence was in.
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") {
                state = .text
                kept.append(byte)
                continue
            }
            switch state {
            case .text:
                if byte == escape { state = .escape } else { kept.append(byte) }
            case .escape:
                // A control sequence (`ESC [`) runs to its final byte; any other two-byte escape ends with the byte after ESC.
                if byte == open {
                    state = .csi
                } else if byte != escape {
                    state = .text
                }
            case .csi:
                if byte == escape {
                    state = .escape
                } else if byte >= 0x40 && byte <= 0x7E {
                    state = .text
                } else if byte < 0x20 || byte > 0x3F {
                    state = .text
                }
            // Parameter and intermediate bytes (0x20 to 0x3F) are dropped inside the sequence.
            }
        }
        return kept
    }
}

/// What a container run has said, for the log view: the container's output (bounded, and passed through the console filter
/// because the container is untrusted), the runner's phases, the container's and the runner's exit statuses and the errors the
/// runner reported, and the runner's own diagnostics from its standard error.
@MainActor @Observable
final class ContainerLog {
    static let defaultLimit = 1024 * 1024
    static let diagnosticsLimit = 64 * 1024
    static let maxErrors = 16
    static let maxErrorCharacters = 1024
    static let maxPhases = 16
    static let maxPhaseNameCharacters = 64

    /// A phase the runner finished and how long it took.
    struct Phase: Equatable, Sendable {
        let name: String
        let seconds: Double
    }

    /// The container's output, both streams in the order they arrived.
    private(set) var output: BoundedText
    /// What the runner wrote to its standard error.
    private(set) var diagnostics = BoundedText(limit: ContainerLog.diagnosticsLimit)
    private(set) var phases: [Phase] = []
    /// The container process's exit status, once it ended.
    private(set) var containerStatus: Int32?
    /// The runner's own exit status as it reported it in its last line.
    private(set) var finishedStatus: Int32?
    private(set) var errors: [String] = []
    /// Lines of the runner's output that were not an event this app knows.
    private(set) var ignoredLines = 0
    /// Lines of the runner's output dropped for their length.
    private(set) var droppedLines = 0

    @ObservationIgnored private var filters: [ContainerStream: ConsoleOutputFilter] = [:]
    @ObservationIgnored private var diagnosticsFilter = ConsoleOutputFilter()
    @ObservationIgnored private var strippers: [ContainerStream: EscapeSequenceStripper] = [:]
    @ObservationIgnored private var diagnosticsStripper = EscapeSequenceStripper()

    init(limit: Int = ContainerLog.defaultLimit) {
        output = BoundedText(limit: limit)
    }

    func apply(_ event: ContainerEvent) {
        switch event {
        case .phase(let name, let seconds):
            guard phases.count < Self.maxPhases else { return }
            phases.append(Phase(name: String(Self.plain(name).prefix(Self.maxPhaseNameCharacters)), seconds: seconds))
        case .output(let stream, let text):
            var filter = filters[stream] ?? ConsoleOutputFilter()
            var stripper = strippers[stream] ?? EscapeSequenceStripper()
            output.append(Self.displayable(stripper.pass(filter.pass(Array(text.utf8)[...]))))
            filters[stream] = filter
            strippers[stream] = stripper
        case .exited(let status):
            containerStatus = status
        case .error(let message):
            guard errors.count < Self.maxErrors else { return }
            errors.append(String(Self.plain(message).prefix(Self.maxErrorCharacters)))
        case .finished(let status):
            finishedStatus = status
        }
    }

    /// What the runner wrote to its standard error.
    func appendDiagnostics(_ bytes: [UInt8]) {
        diagnostics.append(Self.displayable(diagnosticsStripper.pass(diagnosticsFilter.pass(bytes[...]))))
    }

    func noteIgnoredLine() { ignoredLines += 1 }

    func noteDroppedLines(total: Int) { droppedLines = total }

    /// A runner's text with everything the console filter removes taken out.
    private static func plain(_ text: String) -> String {
        var filter = ConsoleOutputFilter()
        var stripper = EscapeSequenceStripper()
        let bytes = displayable(stripper.pass(filter.pass(Array(text.utf8)[...])))
        return String(decoding: bytes, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
    }

    /// What is left of filtered bytes that a text view may show: every format and control character except a line feed and a
    /// tab is dropped. The console filter does not remove them all, so a carriage return, a backspace, a bell, the bidirectional
    /// overrides and the zero-width characters are removed here.
    static func displayable(_ bytes: [UInt8]) -> [UInt8] {
        var kept = ""
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {  // swiftlint:disable:this optional_data_string_conversion
            let category = scalar.properties.generalCategory
            if scalar == "\n" || scalar == "\t" || (category != .format && category != .control) {
                kept.unicodeScalars.append(scalar)
            }
        }
        return Array(kept.utf8)
    }
}

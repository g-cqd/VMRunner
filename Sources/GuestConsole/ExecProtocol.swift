/// What a console is showing, as far as a client needs to know.
public enum ConsolePrompt: Equatable, Sendable {
    /// `login:` waits for a user name.
    case login
    /// `Password:` waits for a password.
    case password
    /// A shell prompt (`# ` or `$ `) waits for a command.
    case shell
}

/// Recognises a prompt at the end of what a console printed. Pure: bytes in, verdict out.
public enum PromptClassifier {
    /// How much of the end of the text is looked at.
    static let window = 256

    /// The prompt `tail` ends with, or `nil` when it ends in anything else (output in progress, or a finished line).
    /// Escape sequences and other control characters are ignored; a prompt is the unfinished last line.
    public static func classify(_ tail: [UInt8]) -> ConsolePrompt? {
        let text = lossyText(tail.suffix(window))
        var scalars = String.UnicodeScalarView()
        for scalar in strippingEscapes(text).unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                scalars.removeAll()
            } else if scalar.value >= 0x20, scalar.value != 0x7F {
                scalars.append(scalar)
            }
        }
        let line = String(scalars)
        var trimmed = line
        while trimmed.last == " " { trimmed.removeLast() }
        let lowered = trimmed.lowercased()
        if lowered.hasSuffix("login:") { return .login }
        if lowered.hasSuffix("password:") { return .password }
        return endsInShellPrompt(line) ? .shell : nil
    }

    /// A shell prompt ends in `#` or `$` and at most one space. A progress bar (`50% ####` followed by blanks, or a full row
    /// of `#`) is not one: it has blanks after its last `#`, or another `#` before it.
    private static func endsInShellPrompt(_ line: String) -> Bool {
        var prompt = line
        if prompt.last == " " { prompt.removeLast() }
        guard let sigil = prompt.last, sigil == "#" || sigil == "$" else { return false }
        return prompt.dropLast().last != "#"
    }

    /// `text` without CSI escape sequences (`ESC [ ... final`) and bare `ESC` characters.
    static func strippingEscapes(_ text: String) -> String {
        var result = ""
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            guard next == "[" else { continue }
            while let following = iterator.next(), !(0x40...0x7E).contains(following.value) {}
        }
        return result
    }
}

/// The result of one command run on the console.
public struct ExecResult: Equatable, Sendable {
    /// What the command printed, with line ends as `\n`. Standard output and error are mixed, as on a terminal.
    public var output: String
    /// The command's exit status (`$?`).
    public var status: Int32

    public init(output: String, status: Int32) {
        self.output = output
        self.status = status
    }
}

/// The markers that frame a command's output on a terminal, and the scanner that finds them in what the console sends back.
///
/// The line typed into the guest is `echo MARK_S_<nonce>; <command>; echo MARK_E_<nonce>_$?`. The terminal may echo it, in
/// pieces and with line editing; the shell then prints the start marker on a line of its own, the command's output, and the
/// end marker with the exit status. The echo never matches: there the start marker is followed by `;`, and the end marker by
/// `$?` and not by digits. So the scanner accepts the start marker only as a whole line, and the end marker only when digits
/// and a line end follow.
public struct ExecMarkers: Equatable, Sendable {
    public let nonce: String

    public init(nonce: String) {
        self.nonce = nonce
    }

    public var start: String { "MARK_S_\(nonce)" }
    public var endPrefix: String { "MARK_E_\(nonce)_" }

    /// The line to type, including its newline.
    public func line(for command: String) -> String {
        "echo \(start); \(command); echo \(endPrefix)$?\n"
    }
}

/// Finds a command's output between its markers in a stream that arrives in arbitrary pieces.
public struct ExecScanner: Sendable {
    public enum Progress: Equatable, Sendable {
        case needMore
        case finished(ExecResult)
        /// More than `limit` bytes of output.
        case overflow
    }

    private let start: [UInt8]
    private let endPrefix: [UInt8]
    private let limit: Int
    private var buffer: [UInt8] = []
    /// Where the start marker's line ended; nil until the start marker was seen.
    private var outputOffset: Int?
    /// Positions before this cannot begin a marker that matches.
    private var scanned = 0

    /// `limit` bounds the bytes kept, so a command that never stops printing cannot fill the memory.
    public init(markers: ExecMarkers, limit: Int = 16 << 20) {
        start = Array(markers.start.utf8)
        endPrefix = Array(markers.endPrefix.utf8)
        self.limit = limit
    }

    /// Bytes received so far that belong to no result yet, most recent last (for an error message).
    public var received: [UInt8] { buffer }

    public mutating func feed(_ bytes: [UInt8]) -> Progress {
        buffer.append(contentsOf: bytes)
        if outputOffset == nil { findStart() }
        if let outputOffset {
            if let result = findEnd(after: outputOffset) { return .finished(result) }
            if buffer.count - outputOffset > limit + endPrefix.count + 8 { return .overflow }
        } else if buffer.count > limit {
            // Nothing but echo and noise so far; keep the end, where the marker will show up.
            let surplus = buffer.count - limit
            buffer.removeFirst(surplus)
            scanned = max(scanned - surplus, 0)
        }
        return .needMore
    }

    // MARK: Scanning

    private mutating func findStart() {
        var index = max(scanned, 0)
        while let found = Self.find(start, in: buffer, from: index) {
            let atLineStart = found == 0 || buffer[found - 1] == 0x0A || buffer[found - 1] == 0x0D
            let after = found + start.count
            guard atLineStart else {
                index = found + 1
                continue
            }
            guard after < buffer.count else {
                // The line end has not arrived: look here again when it does.
                scanned = found
                return
            }
            if buffer[after] == 0x0D || buffer[after] == 0x0A {
                outputOffset = after
                scanned = after
                return
            }
            index = found + 1
        }
        scanned = max(buffer.count - start.count + 1, scanned, 0)
    }

    private mutating func findEnd(after offset: Int) -> ExecResult? {
        var index = max(scanned, offset)
        while let found = Self.find(endPrefix, in: buffer, from: index) {
            var cursor = found + endPrefix.count
            var status = 0
            var digits = 0
            while cursor < buffer.count, digits < 3, (0x30...0x39).contains(buffer[cursor]) {
                status = status * 10 + Int(buffer[cursor] - 0x30)
                digits += 1
                cursor += 1
            }
            guard digits > 0 else {
                if cursor >= buffer.count {
                    // The prefix is the last thing received: the status has not arrived yet.
                    scanned = found
                    return nil
                }
                // `$?` as typed (the echo), or something else: not the marker.
                index = found + 1
                continue
            }
            guard cursor < buffer.count else {
                // The status or the line end is still on its way.
                scanned = found
                return nil
            }
            guard buffer[cursor] == 0x0D || buffer[cursor] == 0x0A else {
                index = found + 1
                continue
            }
            return ExecResult(output: Self.text(of: buffer[offset..<found]), status: Int32(status))
        }
        scanned = max(buffer.count - endPrefix.count + 1, scanned, offset)
        return nil
    }

    /// The output: the end of the marker's own line dropped, `\r\n` turned into `\n`.
    static func text(of region: ArraySlice<UInt8>) -> String {
        var bytes = Array(region)
        if bytes.starts(with: [0x0D, 0x0A]) {
            bytes.removeFirst(2)
        } else if bytes.first == 0x0A || bytes.first == 0x0D {
            bytes.removeFirst()
        }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(bytes.count)
        for (index, byte) in bytes.enumerated() where !(byte == 0x0D && index + 1 < bytes.count && bytes[index + 1] == 0x0A) {
            normalized.append(byte)
        }
        return lossyText(normalized)
    }

    /// The first position at or after `from` where `pattern` occurs in `bytes`.
    static func find(_ pattern: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard let first = pattern.first, bytes.count >= pattern.count else { return nil }
        var index = max(from, 0)
        let last = bytes.count - pattern.count
        while index <= last {
            if bytes[index] == first, bytes[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
            index += 1
        }
        return nil
    }
}

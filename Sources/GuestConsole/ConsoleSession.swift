import Foundation
import Synchronization

/// What one read from a console transport produced.
public enum TransportRead: Equatable, Sendable {
    case bytes([UInt8])
    /// The console ended.
    case endOfStream
    /// Nothing arrived within the time given.
    case timedOut
}

/// A byte stream to a console, with a clock. The session is written against this so its timing can be tested without waiting.
public protocol ConsoleTransport {
    /// Waits up to `timeout` for bytes. Returns `.timedOut` only after the timeout has passed on ``uptime``'s clock.
    func read(timeout: Duration) throws -> TransportRead
    func write(_ bytes: [UInt8]) throws
    /// A monotonic reading, from any origin.
    var uptime: Duration { get }
    func close()
}

/// The real transport: a connected local socket.
public final class SocketTransport: ConsoleTransport {
    private static let readSize = 16 * 1024
    private static let writeStall: Int32 = 5_000

    private let descriptor: Int32
    private let origin = ContinuousClock.now
    private let open = Mutex(true)

    /// Connects to the console at `path`.
    public static func connect(to path: String) throws -> SocketTransport {
        SocketTransport(descriptor: try ConsoleSocket.connect(to: path))
    }

    /// Wraps an already connected socket, which the transport then owns.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    public var uptime: Duration { ContinuousClock.now - origin }

    public func read(timeout: Duration) throws -> TransportRead {
        let parts = timeout.components
        let milliseconds = Int32(clamping: parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        guard ConsoleSocket.wait(descriptor, milliseconds: max(milliseconds, 0)) else { return .timedOut }
        var buffer = [UInt8](repeating: 0, count: Self.readSize)
        switch ConsoleSocket.read(descriptor, into: &buffer) {
        case .transferred(let count): return .bytes(Array(buffer[0..<count]))
        case .wouldBlock: return .timedOut
        case .endOfStream: return .endOfStream
        case .failed(let code): throw ConsoleError.system(call: "read", code: code)
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        try ConsoleSocket.writeAll(descriptor, bytes, stallMilliseconds: Self.writeStall)
    }

    public func close() {
        let wasOpen = open.withLock { isOpen -> Bool in
            defer { isOpen = false }
            return isOpen
        }
        if wasOpen { ConsoleSocket.close(descriptor) }
    }
}

/// A client of a guest console that can wait for a prompt, log in and run commands, and read their output and exit status.
///
/// One session is used from one thread at a time. Every wait takes a timeout and fails with ``ConsoleError/timedOut(waitingFor:tail:)``
/// naming what it waited for; when the console ends, with ``ConsoleError/closed(lastOutput:)``.
public final class ConsoleSession {
    /// Silence before a coaxing newline is sent while waiting for a prompt, and the gap between such newlines.
    static let quietBeforeNudge = Duration.seconds(1)
    static let nudgeInterval = Duration.seconds(2)
    /// Longest command line sent; the terminal's line buffer holds 4095 bytes.
    public static let commandLimit = 3_500
    /// Logins tried before giving up.
    static let loginAttempts = 3

    private let transport: any ConsoleTransport
    private let makeNonce: () -> String
    private let outputLimit: Int
    /// The last bytes received, kept for prompt detection and for error messages.
    private var recent: [UInt8] = []
    /// The prompt the last wait found, until something is typed: asking again does not wait for a prompt that was already seen.
    private var shownPrompt: ConsolePrompt?

    public init(
        transport: any ConsoleTransport, outputLimit: Int = 16 << 20, nonce: @escaping () -> String = ConsoleSession.randomNonce
    ) {
        self.transport = transport
        self.outputLimit = outputLimit
        makeNonce = nonce
    }

    /// Connects to the console socket at `path`. A console that already has a client answers with its busy line:
    /// that shows up as ``ConsoleError/busy`` on the first wait.
    public static func connect(to path: String) throws -> ConsoleSession {
        ConsoleSession(transport: try SocketTransport.connect(to: path))
    }

    public static func randomNonce() -> String {
        String(UInt64.random(in: 0...UInt64.max), radix: 16, uppercase: false)
    }

    public func close() {
        transport.close()
    }

    // MARK: Prompts

    /// Reads until the console shows a login, password or shell prompt. A console that stays quiet is nudged with a newline.
    @discardableResult
    public func waitForPrompt(timeout: Duration) throws -> ConsolePrompt {
        if let shownPrompt { return shownPrompt }
        let deadline = transport.uptime + timeout
        var lastActivity = transport.uptime
        var lastNudge: Duration?
        while true {
            if let prompt = PromptClassifier.classify(recent) {
                recent.removeAll()
                shownPrompt = prompt
                return prompt
            }
            let now = transport.uptime
            guard now < deadline else { throw timedOut("a prompt") }
            let step = min(deadline - now, Self.quietBeforeNudge)
            switch try transport.read(timeout: step) {
            case .bytes(let bytes):
                remember(bytes)
                lastActivity = transport.uptime
            case .endOfStream:
                throw closed()
            case .timedOut:
                let quiet = transport.uptime - lastActivity
                if quiet >= Self.quietBeforeNudge, lastNudge.map({ transport.uptime - $0 >= Self.nudgeInterval }) ?? true {
                    try transport.write([0x0A])
                    lastNudge = transport.uptime
                }
            }
        }
    }

    /// Gets to a shell: answers a `login:` prompt with `user`, a `Password:` prompt with `password` (an empty one by default,
    /// which is what Alpine's live image takes), and returns once a shell prompt shows. Returns at once when one shows already.
    public func login(user: String, password: String = "", timeout: Duration) throws {
        guard !user.isEmpty, !user.contains(where: \.isNewline) else {
            throw ConsoleError.invalidCommand("a user name is one line and not empty")
        }
        let deadline = transport.uptime + timeout
        var logins = 0
        while true {
            let remaining = deadline - transport.uptime
            guard remaining > .zero else { throw timedOut("a shell prompt after logging in") }
            switch try waitForPrompt(timeout: remaining) {
            case .shell:
                return
            case .login:
                logins += 1
                guard logins <= Self.loginAttempts else { throw ConsoleError.loginFailed("the console keeps asking for a login") }
                try send(Array((user + "\n").utf8))
            case .password:
                try send(Array((password + "\n").utf8))
            }
        }
    }

    // MARK: Commands

    /// Runs `command` as one line in the shell the console shows and returns what it printed and its exit status.
    ///
    /// The line is `echo MARK_S_<nonce>; <command>; echo MARK_E_<nonce>_$?`. A command that outlives `timeout` gets Ctrl-C and
    /// the call fails; the shell is then probably usable again, but anything the command printed later is dropped.
    public func run(_ command: String, timeout: Duration) throws -> ExecResult {
        guard !command.contains(where: \.isNewline) else {
            throw ConsoleError.invalidCommand("a command is one line; wrap a script in sh -c '...'")
        }
        let markers = ExecMarkers(nonce: makeNonce())
        let line = Array(markers.line(for: command).utf8)
        guard line.count <= Self.commandLimit else {
            throw ConsoleError.invalidCommand("the line is \(line.count) bytes; at most \(Self.commandLimit) fit the terminal")
        }
        var scanner = ExecScanner(markers: markers, limit: outputLimit)
        recent.removeAll()
        try send(line)
        let deadline = transport.uptime + timeout
        while true {
            let now = transport.uptime
            guard now < deadline else {
                try? transport.write([0x03])
                throw ConsoleError.timedOut(
                    waitingFor: "the command to finish", tail: Self.excerpt(scanner.received.suffix(Self.excerptBytes)))
            }
            switch try transport.read(timeout: deadline - now) {
            case .bytes(let bytes):
                switch scanner.feed(bytes) {
                case .finished(let result): return result
                case .overflow: throw ConsoleError.outputTooLarge(limit: outputLimit)
                case .needMore: break
                }
            case .endOfStream:
                throw Self.ended(after: scanner.received)
            case .timedOut:
                break
            }
        }
    }

    /// Types `bytes`; what the console showed before is no longer the current prompt.
    private func send(_ bytes: [UInt8]) throws {
        shownPrompt = nil
        try transport.write(bytes)
    }

    // MARK: Messages

    static let recentLimit = 4_096
    static let excerptBytes = 400

    private func remember(_ bytes: [UInt8]) {
        recent.append(contentsOf: bytes)
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    private func timedOut(_ waitingFor: String) -> ConsoleError {
        .timedOut(waitingFor: waitingFor, tail: Self.excerpt(recent.suffix(Self.excerptBytes)))
    }

    private func closed() -> ConsoleError {
        Self.ended(after: recent)
    }

    /// The error for a console that ended after sending `received`: ``ConsoleError/busy`` when that is the busy line of a console
    /// that already has a client, an ordinary end otherwise.
    static func ended(after received: [UInt8]) -> ConsoleError {
        let busy = Array(ConsoleBridge.busyMessage.utf8.dropLast())
        if received.starts(with: busy) { return .busy }
        return .closed(lastOutput: excerpt(received.suffix(excerptBytes)))
    }

    /// Printable text for an error message: line ends as `\n`, other control characters shown as `.`, trimmed.
    static func excerpt(_ bytes: ArraySlice<UInt8>) -> String {
        let text = lossyText(bytes)
        let shown = text.unicodeScalars.compactMap { scalar -> String? in
            if scalar == "\r" { return nil }
            return scalar.value < 0x20 && scalar != "\n" || scalar.value == 0x7F ? "." : String(scalar)
        }
        return shown.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

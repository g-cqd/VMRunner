import Foundation

/// Relays bytes between a person's terminal and a console socket until one side ends, the person detaches or the caller
/// wakes it. What the person types reaches the console unchanged; what the console prints passes through a
/// ``ConsoleOutputFilter`` first, unless the caller gives none.
public enum ConsoleRelay {
    /// Control-] (as in telnet): typed on the input, it ends the relay.
    public static let detachByte: UInt8 = 0x1D

    public enum Ending: Equatable, Sendable {
        /// The console closed.
        case consoleClosed
        /// The input ended.
        case inputEnded
        /// The person typed the detach byte.
        case detached
        /// The `wake` descriptor became readable (the caller's signal watch, for one).
        case interrupted
    }

    /// Connects to the console at `socketPath` and relays until it ends. A console that has a client answers with one line and
    /// closes, which shows up as `.consoleClosed` after that line was copied to `output`.
    public static func run(
        socketPath: String, input: Int32, output: Int32, filter: ConsoleOutputFilter?, wake: Int32 = -1
    ) throws -> Ending {
        let console = try ConsoleSocket.connect(to: socketPath)
        defer { ConsoleSocket.close(console) }
        return try run(console: console, input: input, output: output, filter: filter, wake: wake)
    }

    /// Relays `input` to the connected socket `console`, and the console's output to `output` through `filter` when there is
    /// one. When `wake` (never polled when negative) becomes readable the relay ends with `.interrupted`. The caller puts a
    /// terminal into raw mode first, when there is one; this does not touch terminal settings.
    public static func run(
        console: Int32, input: Int32, output: Int32, filter: ConsoleOutputFilter?, wake: Int32 = -1
    ) throws -> Ending {
        var filter = filter
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var entries = [
                pollfd(fd: console, events: Int16(POLLIN), revents: 0), pollfd(fd: input, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake, events: Int16(POLLIN), revents: 0),
            ]
            // Three entries, three descriptors; poll skips a negative one.
            let ready = unsafe poll(&entries, 3, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ConsoleError.system(call: "poll", code: errno)
            }
            // Drain the console first, so output that arrived before a detach or the end of the input is not lost.
            if entries[0].revents != 0 {
                switch ConsoleSocket.read(console, into: &buffer) {
                case .transferred(let count):
                    let shown = filter?.pass(buffer[0..<count]) ?? Array(buffer[0..<count])
                    if !shown.isEmpty { try ConsoleSocket.writeAll(output, shown, stallMilliseconds: 10_000) }
                case .wouldBlock: break
                case .endOfStream, .failed: return .consoleClosed
                }
            }
            if entries[1].revents != 0 {
                switch ConsoleSocket.read(input, into: &buffer) {
                case .transferred(let count):
                    let typed = Array(buffer[0..<count])
                    let detach = typed.firstIndex(of: detachByte)
                    try ConsoleSocket.writeAll(console, Array(typed[0..<(detach ?? typed.count)]), stallMilliseconds: 10_000)
                    if detach != nil { return .detached }
                case .wouldBlock: break
                case .endOfStream, .failed: return .inputEnded
                }
            }
            if entries[2].revents != 0 { return .interrupted }
        }
    }

    /// What to write to the person's terminal once the relay has ended. Filtered output can only have left colours and
    /// attributes set, so resetting those is enough. Raw output may have set anything, so the modes a guest's programs most
    /// often leave on are turned off too: the alternate screen, mouse and focus reports, bracketed paste, application cursor
    /// keys and keypad, a keyboard protocol, a hidden cursor, autowrap off, a scroll region (reset between saving and
    /// restoring the cursor, as the reset moves it) and a line-drawing character set.
    public static func closingBytes(filtered: Bool) -> [UInt8] {
        let attributes = "\u{1B}[0m"
        guard !filtered else { return Array(attributes.utf8) }
        let modes = [
            "?1049l", "?1000l", "?1002l", "?1003l", "?1005l", "?1006l", "?1015l", "?1004l", "?2004l", "?1l", "=0;1u", "?25h", "?7h",
        ]
        let others = "\u{1B}>" + "\u{1B}7\u{1B}[r\u{1B}8" + "\u{1B}(B\u{0F}"
        return Array((modes.map { "\u{1B}[" + $0 }.joined() + others + attributes).utf8)
    }
}

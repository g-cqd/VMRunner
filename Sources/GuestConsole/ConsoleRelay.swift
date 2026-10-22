import Foundation

/// Copies bytes between a person's terminal and a console socket, unchanged, until one side ends or the person detaches.
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
    }

    /// Connects to the console at `socketPath` and relays until it ends. A console that has a client answers with one line and
    /// closes, which shows up as `.consoleClosed` after that line was copied to `output`.
    public static func run(socketPath: String, input: Int32, output: Int32) throws -> Ending {
        let console = try ConsoleSocket.connect(to: socketPath)
        defer { ConsoleSocket.close(console) }
        return try run(console: console, input: input, output: output)
    }

    /// Relays `input` to the connected socket `console` and the console's output to `output`. The caller puts a terminal into raw
    /// mode first, when there is one; this does not touch terminal settings.
    public static func run(console: Int32, input: Int32, output: Int32) throws -> Ending {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var entries = [pollfd(fd: console, events: Int16(POLLIN), revents: 0), pollfd(fd: input, events: Int16(POLLIN), revents: 0)]
            // Two entries, two descriptors.
            let ready = unsafe poll(&entries, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ConsoleError.system(call: "poll", code: errno)
            }
            // Drain the console first, so output that arrived before a detach or the end of the input is not lost.
            if entries[0].revents != 0 {
                switch ConsoleSocket.read(console, into: &buffer) {
                case .transferred(let count): try ConsoleSocket.writeAll(output, Array(buffer[0..<count]), stallMilliseconds: 10_000)
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
        }
    }
}

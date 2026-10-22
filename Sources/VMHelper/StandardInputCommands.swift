import Foundation
import VMHelperCore

/// The command lines the launcher writes to the helper's standard input (`--commands`), as a stream.
///
/// A thread does the reading: a blocking read has no place in a task. The launcher keeps a named pipe open for writing, so
/// the stream ends only if the pipe is closed on every side.
enum StandardInputCommands {
    enum Line: Sendable, Equatable {
        case command(HelperCommand)
        /// A line that is not a command; the text says why.
        case unreadable(String)
    }

    /// The longest line kept; a longer one is skipped as a whole.
    static let lineLimit = 4_096

    static func stream() -> AsyncStream<Line> {
        let (stream, continuation) = AsyncStream.makeStream(of: Line.self)
        let thread = Thread {
            var pending = Data()
            var skipping = false
            var buffer = [UInt8](repeating: 0, count: 1_024)
            // `FileHandle.read(upToCount:)` waits for the whole count on a pipe; a command line is far shorter than that.
            while true {
                let count = buffer.withUnsafeMutableBytes { unsafe read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                for byte in buffer[0..<count] {
                    guard byte == 0x0A else {
                        if pending.count < lineLimit { pending.append(byte) } else { skipping = true }
                        continue
                    }
                    if skipping {
                        continuation.yield(.unreadable("a command line longer than \(lineLimit) bytes"))
                    } else if let line = Self.line(String(bytes: pending, encoding: .utf8)) {
                        continuation.yield(line)
                    }
                    pending.removeAll(keepingCapacity: true)
                    skipping = false
                }
            }
            continuation.finish()
        }
        thread.name = "VMHelper.commands"
        thread.start()
        return stream
    }

    /// What one line says, or `nil` for a blank line.
    static func line(_ text: String?) -> Line? {
        guard let text else { return .unreadable("a command line that is not UTF-8") }
        do {
            return try HelperCommand.parse(text).map(Line.command)
        } catch {
            return .unreadable(error.reason)
        }
    }
}

import Foundation
import GuestConsole
import Synchronization

/// What reading one request line came to.
enum LineRead: Equatable, Sendable {
    case line([UInt8])
    case tooLong
    case closed
    case timedOut
    case failed(Int32)
}

/// Blocking reads and writes of lines on a socket, bounded in size and time. They wait on the socket, so callers run them
/// on a thread of their own (`runOnThread`).
enum LineIO {
    /// Reads until `buffer` holds a whole line, the line is too long, the peer closes, or `timeoutMilliseconds` pass.
    static func readLine(from descriptor: Int32, into buffer: inout LineBuffer, readBytes: Int, timeoutMilliseconds: Int32) -> LineRead {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutMilliseconds))
        var chunk = [UInt8](repeating: 0, count: readBytes)
        while true {
            switch buffer.next() {
            case .line(let bytes): return .line(bytes)
            case .tooLong: return .tooLong
            case .needMore: break
            }
            let left = ContinuousClock.now.duration(to: deadline) / .milliseconds(1)
            guard left > 0, ConsoleSocket.wait(descriptor, milliseconds: Int32(left.rounded(.up))) else { return .timedOut }
            switch ConsoleSocket.read(descriptor, into: &chunk) {
            case .transferred(let count): buffer.append(chunk[..<count])
            case .wouldBlock: continue
            case .endOfStream: return .closed
            case .failed(let code): return .failed(code)
            }
        }
    }

    /// Writes `data` whole; false when the peer is gone or did not read for `stallMilliseconds`.
    static func write(_ data: Data, to descriptor: Int32, stallMilliseconds: Int32) -> Bool {
        do {
            try ConsoleSocket.writeAll(descriptor, Array(data), stallMilliseconds: stallMilliseconds)
            return true
        } catch {
            return false
        }
    }
}

/// Runs blocking `work` on a thread of its own and returns its result, so a wait on a socket never holds one of the threads
/// Swift concurrency shares between tasks.
func runOnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: work()) }
        thread.name = "ControlProtocol.io"
        thread.start()
    }
}

/// Runs `operation` and returns its result, or nil when `timeout` passes first, as `sleep` measures it. The operation is not
/// cancelled: what it started (a machine that boots) goes on, and its result is dropped.
func withDeadline<T: Sendable>(
    _ timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void, _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { continuation in
        let first = FirstAnswer<T>(continuation)
        let timer = Task {
            guard (try? await sleep(timeout)) != nil else { return }
            first.resume(nil)
        }
        Task {
            let value = await operation()
            first.resume(value)
            timer.cancel()
        }
    }
}

/// Resumes a continuation with the first answer it is given and ignores the others.
private final class FirstAnswer<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = Mutex(Optional(continuation))
    }

    func resume(_ value: T?) {
        let waiting = continuation.withLock { stored -> CheckedContinuation<T?, Never>? in
            defer { stored = nil }
            return stored
        }
        waiting?.resume(returning: value)
    }
}

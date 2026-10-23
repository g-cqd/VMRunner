import Foundation
import Synchronization

/// Turns the signals that would end the process into a byte on a pipe while it is active, so a loop that polls
/// ``descriptor`` ends on its own path and the terminal is put back before the process exits.
///
/// No code runs in signal context. Each signal is set to be ignored and is received through a dispatch source instead (the
/// kernel reports a signal to such a source even when it is ignored); the source's handler runs on an ordinary thread and
/// writes the signal's number to the pipe. ``stop()`` gives each signal its default action back.
final class SignalWatch {
    /// The signals the console client watches: the terminal hanging up, an interrupt or a quit sent with `kill` (raw mode
    /// sends the keys to the guest instead), the output closing, and a request to terminate.
    static let ending: [Int32] = [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM]

    /// Readable once a watched signal arrived: one byte per signal, its number.
    let descriptor: Int32
    private let writer: Int32
    private let signals: [Int32]
    private let gate = Gate()
    private var sources: [any DispatchSourceSignal] = []

    /// Whether the pipe may still be written. A handler checks it and writes under the lock, and ``stop()`` closes it under
    /// the lock before closing the pipe, so no handler writes to a closed descriptor.
    private final class Gate: Sendable {
        let isOpen = Mutex(true)
    }

    /// Nil when the pipe cannot be made; the caller then goes on without a watch.
    init?(signals: [Int32]) {
        var ends: [Int32] = [-1, -1]
        // `pipe` fills exactly two descriptors.
        guard unsafe pipe(&ends) == 0 else { return nil }
        for end in ends { _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK) }
        descriptor = ends[0]
        writer = ends[1]
        self.signals = signals
        let shared = gate
        let target = ends[1]
        for number in signals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number)
            source.setEventHandler {
                shared.isOpen.withLock { isOpen in
                    guard isOpen else { return }
                    var byte = UInt8(truncatingIfNeeded: number)
                    // One byte from the stack. A full pipe drops it: one byte is enough to wake the loop.
                    _ = unsafe write(target, &byte, 1)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        stop()
    }

    /// The number of the first watched signal not yet read, or nil when none arrived; does not wait.
    func caught() -> Int32? {
        var byte: UInt8 = 0
        // One byte into the stack.
        return unsafe read(descriptor, &byte, 1) == 1 ? Int32(byte) : nil
    }

    /// Stops watching: no handler writes any more, the sources are cancelled, each signal gets its default action back and
    /// the pipe is closed. Calling it again does nothing.
    func stop() {
        let wasOpen = gate.isOpen.withLock { isOpen in
            defer { isOpen = false }
            return isOpen
        }
        guard wasOpen else { return }
        for source in sources { source.cancel() }
        sources.removeAll()
        for number in signals { signal(number, SIG_DFL) }
        close(descriptor)
        close(writer)
    }
}

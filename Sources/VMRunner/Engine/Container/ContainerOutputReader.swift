import Darwin
import Dispatch
import Foundation
import Synchronization

/// Something that can be held back and let go again, in balance: a reader of a pipe.
protocol Pausable: AnyObject, Sendable {
    func pause()
    func resume()
}

/// How many bytes the readers have queued for the main actor and it has not applied yet. A reader that finds more than
/// `pauseAbove` queued is paused, so a runner that writes faster than the app applies is held back by its full pipe instead of
/// filling memory; the consumer lets the readers go when `resumeBelow` is reached. Pausing and resuming happen under the lock,
/// so a reader is never resumed before it was paused, and a closed backlog pauses nothing: a paused source must be resumed
/// before it is cancelled.
final class OutputBacklog: Sendable {
    static let pauseAbove = 4 * 1024 * 1024
    static let resumeBelow = 1024 * 1024

    private struct State {
        var queued = 0
        var paused: [any Pausable] = []
        var closed = false
    }

    private let state = Mutex(State())

    /// The bytes queued and not applied yet.
    var queuedBytes: Int { state.withLock { $0.queued } }

    /// Counts `count` bytes `reader` is about to queue; pauses it when too much is queued.
    func queued(_ count: Int, from reader: some Pausable) {
        state.withLock { state in
            state.queued += count
            guard !state.closed, state.queued > Self.pauseAbove, !state.paused.contains(where: { $0 === reader }) else { return }
            reader.pause()
            state.paused.append(reader)
        }
    }

    /// Counts `count` queued bytes as applied; lets the readers go when little is left.
    func applied(_ count: Int) {
        guard count > 0 else { return }
        state.withLock { state in
            state.queued -= count
            guard state.queued < Self.resumeBelow else { return }
            Self.releasePaused(&state)
        }
    }

    /// Lets every paused reader go and pauses none again.
    func close() {
        state.withLock { state in
            state.closed = true
            Self.releasePaused(&state)
        }
    }

    private static func releasePaused(_ state: inout State) {
        for reader in state.paused { reader.resume() }
        state.paused = []
    }
}

/// What a ``PipeReader`` reports, in order.
enum PipeReport: Sendable {
    case data([UInt8])
    /// The write side closed and everything was read.
    case ended
    /// The descriptor is closed.
    case closed
}

/// A read end of a pipe the driver owns, followed with a dispatch source. The source's cancel handler closes the descriptor,
/// and dispatch runs it after the last event handler returned, so a read never meets a closed descriptor. (A file handle's
/// readability handler can run once more after the handle was closed, and reading then raises an exception.)
final class PipeReader: Pausable {
    private static let readSize = 64 * 1024

    private enum Chunk {
        case data([UInt8])
        case end
        case retry
    }

    private let source: any DispatchSourceRead

    private init(source: any DispatchSourceRead) {
        self.source = source
    }

    /// Starts following `descriptor`, which the reader owns from now on. A chunk is counted in `backlog` before it is reported.
    /// `report` is called from the reader's own queue.
    static func follow(
        _ descriptor: Int32, backlog: OutputBacklog, ledger: DescriptorLedger, report: @escaping @Sendable (PipeReport) -> Void
    ) -> PipeReader {
        // A read source needs a queue to run its handlers on.
        let queue = DispatchQueue(label: "container-runner-output", qos: .utility)  // swiftlint:disable:this no_dispatch_queue
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let reader = PipeReader(source: source)
        source.setEventHandler {
            switch Self.readChunk(from: descriptor) {
            case .retry:
                return
            case .data(let bytes):
                backlog.queued(bytes.count, from: reader)
                report(.data(bytes))
            case .end:
                report(.ended)
                reader.cancel()
            }
        }
        source.setCancelHandler {
            _ = Darwin.close(descriptor)
            ledger.closed()
            report(.closed)
        }
        source.activate()
        return reader
    }

    func pause() { source.suspend() }

    func resume() { source.resume() }

    /// Stops following and closes the descriptor once the running handler is done. A paused reader must be resumed first.
    func cancel() { source.cancel() }

    /// One read of what is there; the source says the descriptor is readable, so it does not wait.
    private static func readChunk(from descriptor: Int32) -> Chunk {
        withUnsafeTemporaryAllocation(byteCount: readSize, alignment: 1) { buffer in
            let count = unsafe read(descriptor, buffer.baseAddress, buffer.count)
            if count > 0 { return .data(unsafe Array(UnsafeRawBufferPointer(rebasing: buffer[..<count]))) }
            if count == 0 { return .end }
            return errno == EINTR || errno == EAGAIN ? .retry : .end
        }
    }
}

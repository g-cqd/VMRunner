import ContainerRunnerCore
import Containerization
import Foundation
import Synchronization

/// Writes the runner's events to standard output, one JSON line each, and keeps the clock they are stamped with.
///
/// Standard error belongs to diagnostics, so a launcher can read events from standard output without filtering.
final class EventEmitter: Sendable {
    private let start = ContinuousClock.now
    /// Held while a line is written and stamped, so lines from the container's streams never interleave and their times
    /// never run backwards.
    private let lock = Mutex(())

    /// Stamps `event` with the time since the runner started and writes it.
    func send(_ event: RunnerEvent) {
        lock.withLock { _ in
            var stamped = event
            stamped.time = RunnerEvent.seconds(of: ContinuousClock.now - start)
            guard let line = try? stamped.line() else { return }
            try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}

/// A request to stop the container, from a `stop` line or the end of standard input.
///
/// While the run is still being set up (kernel, image, boot) the request ends the runner at once; once the container runs,
/// ``requested()`` returns so the flow can stop the container and end normally.
final class StopSignal: Sendable {
    private struct State {
        var requested = false
        var settingUp = true
    }

    private let state = Mutex(State())
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let whileSettingUp: @Sendable () -> Void

    /// `whileSettingUp` runs on a request that arrives before ``settingUpDone()``; it is expected not to return.
    init(whileSettingUp: @escaping @Sendable () -> Void) {
        (stream, continuation) = AsyncStream.makeStream()
        self.whileSettingUp = whileSettingUp
    }

    var isRequested: Bool { state.withLock { $0.requested } }

    /// The container runs: from now on a request is answered by ``requested()``.
    func settingUpDone() {
        state.withLock { $0.settingUp = false }
    }

    func request() {
        let early = state.withLock { state in
            state.requested = true
            return state.settingUp
        }
        if early { whileSettingUp() }
        continuation.finish()
    }

    /// Returns once a stop was requested, or when the calling task is cancelled. Only one task may wait.
    func requested() async {
        for await _ in stream {}
    }
}

/// Watches standard input for a `stop` line or its end, and asks `signal` to stop. The launcher closing the pipe, or dying,
/// ends the container the same way.
final class StdinWatcher: Sendable {
    private let detector = Mutex(StopLineDetector())
    private let signal: StopSignal

    init(signal: StopSignal) {
        self.signal = signal
    }

    func start() {
        FileHandle.standardInput.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard data.isEmpty || detector.withLock({ $0.feed(data) }) else { return }
            handle.readabilityHandler = nil
            signal.request()
        }
    }
}

/// Collects what the container writes, keeping at most `limit` bytes: the verdict needs the start of the output, not all of it.
final class OutputCapture: Sendable {
    private let bytes = Mutex(Data())
    private let limit: Int

    init(limit: Int = .max) {
        self.limit = limit
    }

    /// What was kept, decoded leniently: a limit may cut a character in two.
    var text: String { bytes.withLock { String(decoding: $0, as: UTF8.self) } }  // swiftlint:disable:this optional_data_string_conversion

    func append(_ data: Data) {
        bytes.withLock { $0.append(data.prefix(max(0, limit - $0.count))) }
    }
}

/// Receives what the container writes to one stream: it goes into the capture and, with an emitter, out as `output` events.
struct StreamWriter: Writer {
    let capture: OutputCapture
    let stream: RunnerEvent.Stream
    let emitter: EventEmitter?

    func write(_ data: Data) throws {
        capture.append(data)
        for chunk in RunnerEvent.chunks(of: data) {
            let text = String(decoding: chunk, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
            emitter?.send(RunnerEvent(.output, stream: stream, text: text))
        }
    }

    func close() throws {}
}

/// The kinds of input event the latency monitor tells apart.
enum InputKind: CaseIterable, Sendable {
    case key, pointer
    /// Scroll wheel and trackpad gestures.
    case scroll

    var label: String {
        switch self {
        case .key: "key"
        case .pointer: "pointer"
        case .scroll: "scroll"
        }
    }
}

/// How much of one stretch of main-thread work a named, instrumented piece of code took.
struct WorkShare: Sendable, Equatable {
    var name: String
    var duration: UInt64
    var count: Int
}

/// One stretch of main-thread work above the threshold, with the instrumented work that ran inside it.
struct LoopStall: Sendable, Equatable {
    /// From the run loop waking up to it going back to sleep.
    var duration: UInt64
    /// The part of ``duration`` before the run loop first looked at its sources (timers, wake-up messages, queued main-actor jobs).
    var wake: UInt64
    /// How many times the run loop went round without sleeping.
    var passes: Int
    /// Instrumented work inside the stretch, longest first. Nested work overlaps, so the shares can add up to more than
    /// ``duration``; what they leave out is work nobody has instrumented.
    var work: [WorkShare]
}

/// Follows the main run loop's busy stretches from its own callbacks, in nanoseconds the caller reads from any monotonic clock.
///
/// A stretch starts when the run loop wakes up and ends when it is about to sleep again. The run loop may go round several
/// times in between, and AppKit hands events to views between two runs of the loop, so only sleeping counts as idle.
struct LoopStallTracker: Sendable {
    /// The most distinct names one stretch keeps; work past that is not attributed.
    static let nameLimit = 8

    struct Stretch: Sendable, Equatable {
        var duration: UInt64
        var wake: UInt64
        var passes: Int
    }

    private var wokeAt: UInt64?
    private var firstSourcesAt: UInt64?
    private var passes = 0
    private var open: [(name: String, start: UInt64)] = []
    private var shares: [WorkShare] = []

    mutating func wake(at now: UInt64) {
        wokeAt = now
        firstSourcesAt = nil
        passes = 0
        open.removeAll(keepingCapacity: true)
        shares.removeAll(keepingCapacity: true)
    }

    mutating func beforeSources(at now: UInt64) {
        guard wokeAt != nil else { return }
        passes += 1
        if firstSourcesAt == nil { firstSourcesAt = now }
    }

    /// Ends the stretch. `nil` when the loop was not seen waking up (the observer started mid-stretch).
    mutating func beforeWaiting(at now: UInt64) -> Stretch? {
        guard let start = wokeAt else { return nil }
        wokeAt = nil
        return Stretch(duration: now &- start, wake: (firstSourcesAt ?? now) &- start, passes: passes)
    }

    mutating func begin(_ name: String, at now: UInt64) {
        open.append((name, now))
    }

    /// Ends the innermost piece of work begun. Ignored when none is open.
    mutating func end(at now: UInt64) {
        guard let work = open.popLast() else { return }
        let elapsed = now &- work.start
        if let index = shares.firstIndex(where: { $0.name == work.name }) {
            shares[index].duration &+= elapsed
            shares[index].count += 1
        } else if shares.count < Self.nameLimit {
            shares.append(WorkShare(name: work.name, duration: elapsed, count: 1))
        }
    }

    /// The work attributed to the stretch so far, longest first.
    var work: [WorkShare] { shares.sorted { $0.duration > $1.duration } }
}

/// What the latency monitor has seen: how late input events reached the app, and how long the main thread stayed busy.
struct InputLatencyStats: Sendable, Equatable {
    /// The stalls kept, worst first.
    static let stallsKept = 3

    private(set) var key: LatencyHistogram
    private(set) var pointer: LatencyHistogram
    private(set) var scroll: LatencyHistogram
    private(set) var busy: LatencyHistogram
    private(set) var worstStalls: [LoopStall] = []

    init(threshold: UInt64) {
        key = LatencyHistogram(threshold: threshold)
        pointer = key
        scroll = key
        busy = key
    }

    func events(_ kind: InputKind) -> LatencyHistogram {
        switch kind {
        case .key: key
        case .pointer: pointer
        case .scroll: scroll
        }
    }

    mutating func recordEvent(_ kind: InputKind, age: UInt64) {
        switch kind {
        case .key: key.record(age)
        case .pointer: pointer.record(age)
        case .scroll: scroll.record(age)
        }
    }

    /// Counts one busy stretch; `stall` is given when it was above the threshold.
    mutating func recordStretch(_ duration: UInt64, stall: LoopStall?) {
        busy.record(duration)
        guard let stall else { return }
        worstStalls.append(stall)
        worstStalls.sort { $0.duration > $1.duration }
        if worstStalls.count > Self.stallsKept { worstStalls.removeLast() }
    }
}

/// The pure core of the input latency monitor: it takes event ages and run-loop callbacks as numbers and keeps two sets of
/// statistics, one for the current reporting window and one for the whole run. Nothing here reads a clock or touches AppKit.
struct InputLatencyRecorder: Sendable {
    let threshold: UInt64
    private(set) var window: InputLatencyStats
    private(set) var total: InputLatencyStats
    private var loop = LoopStallTracker()

    init(threshold: UInt64) {
        self.threshold = threshold
        window = InputLatencyStats(threshold: threshold)
        total = window
    }

    /// How long ago an event happened: both times are seconds on the clock that starts at system boot, which is what an
    /// event's timestamp and `ProcessInfo.systemUptime` use. An event stamped in the future, or a time that is not a
    /// number, counts as no delay.
    static func age(timestamp: Double, now: Double) -> UInt64 {
        let seconds = now - timestamp
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64((min(seconds, 1_000) * 1_000_000_000).rounded())
    }

    mutating func recordEvent(_ kind: InputKind, age: UInt64) {
        window.recordEvent(kind, age: age)
        total.recordEvent(kind, age: age)
    }

    mutating func loopWoke(at now: UInt64) { loop.wake(at: now) }

    mutating func loopWillLookAtSources(at now: UInt64) { loop.beforeSources(at: now) }

    /// Closes the busy stretch. Returns it when it was longer than the threshold.
    @discardableResult
    mutating func loopWillSleep(at now: UInt64) -> LoopStall? {
        guard let stretch = loop.beforeWaiting(at: now) else { return nil }
        let stall =
            stretch.duration > threshold
            ? LoopStall(duration: stretch.duration, wake: stretch.wake, passes: stretch.passes, work: loop.work) : nil
        window.recordStretch(stretch.duration, stall: stall)
        total.recordStretch(stretch.duration, stall: stall)
        return stall
    }

    mutating func workBegan(_ name: String, at now: UInt64) { loop.begin(name, at: now) }

    mutating func workEnded(at now: UInt64) { loop.end(at: now) }

    /// Hands over the window's statistics and starts a new window.
    mutating func rollWindow() -> InputLatencyStats {
        defer { window = InputLatencyStats(threshold: threshold) }
        return window
    }
}

import AppKit
import Foundation
import Virtualization
import os

/// The AppKit side of the input latency monitor (``InputLatencyOptions`` says how to turn it on). It only observes: a local
/// event monitor that hands every event back unchanged, and run-loop observers. The numbers are kept and worked out in
/// ``InputLatencyCollector``; this type reads the clock, the events and the run loop, and writes the signposts.
///
/// Off, it does not exist: ``current`` is `nil`, and the ``InputPath`` calls scattered through the app cost one test of it.
@MainActor
final class InputLatencyMonitor {
    /// The running monitor, or `nil` when it was not asked for.
    private(set) static var current: InputLatencyMonitor?

    /// A piece of main-thread work that has started, to be handed back to ``InputPath/end(_:)``.
    struct Work {
        fileprivate let interval: InputSignposts.Interval
    }

    private static let eventMask: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged,
        .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify, .pressure, .beginGesture, .endGesture,
    ]

    /// Which statistics an event type belongs to; `nil` for types the monitor does not follow.
    nonisolated static func kind(of type: NSEvent.EventType) -> InputKind? {
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            .key
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            .pointer
        case .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify, .pressure, .beginGesture, .endGesture:
            .scroll
        default:
            nil
        }
    }

    /// Starts the monitor when the launch arguments or the environment ask for it. Call once, after the app has launched.
    static func startIfRequested(
        arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard current == nil else { return }
        let parsed = InputLatencyOptions.parse(arguments: arguments, environment: environment)
        for warning in parsed.warnings { Log.input.error("Input latency monitor: \(warning, privacy: .public)") }
        guard let options = parsed.options else { return }
        let monitor = InputLatencyMonitor(options: options)
        monitor.start()
        current = monitor
    }

    private let options: InputLatencyOptions
    private let collector: InputLatencyCollector
    private let signposts = InputSignposts()
    /// Which windows showed a machine when last looked at; only the events of those are measured.
    private var machineWindows: [ObjectIdentifier: (showsMachine: Bool, checkedAt: UInt64)] = [:]
    private var eventMonitor: Any?
    private var observers: [CFRunLoopObserver] = []
    private var busy: InputSignposts.Interval?

    private init(options: InputLatencyOptions) {
        self.options = options
        let file = options.file
        collector = InputLatencyCollector(threshold: options.threshold) { line in
            Log.input.notice("\(line, privacy: .public)")
            if let file { Task.detached(priority: .utility) { LatencySummaryFile.append(line, to: file) } }
        }
    }

    private func start() {
        let threshold = InputLatencyStats.milliseconds(options.threshold)
        let destination = options.file == nil ? "the log" : "the log and a file"
        let interval = options.interval
        Log.input.notice(
            "Input latency monitor on: threshold \(threshold, privacy: .public), every \(interval) s to \(destination, privacy: .public)")
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
        // The first observer to run on waking and the last to run before sleeping, so that what AppKit and Core Animation do
        // in their own observers (layout, display, the transaction commit) counts as busy time.
        observe(.afterWaiting, order: .min)
        observe(.beforeSources, order: 0)
        observe(.beforeWaiting, order: .max)
        collector.startReporting(every: .seconds(options.interval), clock: ContinuousClock())
    }

    /// Stops measuring and writes the totals of the whole run. Call when the app quits.
    func finish() {
        collector.stopReporting()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
        let line = collector.totalLine()
        Log.input.notice("\(line, privacy: .public)")
        if let file = options.file { LatencySummaryFile.append(line, to: file) }
        Self.current = nil
    }

    // MARK: Events

    private func observe(_ event: NSEvent) {
        guard let kind = Self.kind(of: event.type),
            let window = Self.measuredWindow(of: event, keyWindow: NSApplication.shared.keyWindow), showsMachine(window)
        else { return }
        let age = InputLatencyRecorder.age(timestamp: event.timestamp, now: ProcessInfo.processInfo.systemUptime)
        collector.recordEvent(kind, age: age)
        signposts.received(kind, age: age)
    }

    /// The window an event is measured against: its own, or the key window for an event that has none. An event posted to
    /// the process (`CGEventPostToPid`) carries no window number, so AppKit gives a pointer event none; without this, such
    /// events were never counted (roadmap 0037).
    static func measuredWindow(of event: NSEvent, keyWindow: NSWindow?) -> NSWindow? {
        event.window ?? keyWindow
    }

    /// Whether the window holds a machine's view. A window gains and loses it as machines start and stop, so the answer is
    /// looked up again once a second rather than on every event.
    private func showsMachine(_ window: NSWindow) -> Bool {
        let now = Self.nanoseconds()
        let id = ObjectIdentifier(window)
        if let known = machineWindows[id], now &- known.checkedAt < 1_000_000_000 { return known.showsMachine }
        let shows = window.contentView.map(Self.holdsMachineView) ?? false
        machineWindows[id] = (shows, now)
        return shows
    }

    static func holdsMachineView(_ view: NSView) -> Bool {
        view is VZVirtualMachineView || view is CustomGPUView || view.subviews.contains(where: holdsMachineView)
    }

    // MARK: Run loop

    private func observe(_ activity: CFRunLoopActivity, order: CFIndex) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        observers.append(observer)
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = Self.nanoseconds()
        switch activity {
        case .afterWaiting:
            collector.loopWoke(at: now)
            busy = signposts.begin("main busy")
        case .beforeSources:
            collector.loopWillLookAtSources(at: now)
        case .beforeWaiting:
            if let busy { signposts.end(busy) }
            busy = nil
            if let stall = collector.loopWillSleep(at: now) { signposts.stalled(stall) }
        default:
            break
        }
    }

    // MARK: Work

    fileprivate func beginWork(_ name: StaticString) -> Work {
        collector.workBegan(name.description, at: Self.nanoseconds())
        return Work(interval: signposts.begin(name))
    }

    fileprivate func endWork(_ work: Work) {
        collector.workEnded(at: Self.nanoseconds())
        signposts.end(work.interval)
    }

    /// Nanoseconds on the clock that stops while the Mac sleeps, like an event's timestamp.
    private static func nanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// Marks a piece of main-thread work that can delay input, for the latency monitor: it shows as a signposted interval in
/// Instruments and as the named cause of a stall. A no-op unless the monitor was asked for.
///
/// ```swift
/// let work = InputPath.begin("config write")
/// defer { InputPath.end(work) }
/// ```
///
/// Names should stay within 15 bytes, which a Swift string keeps inline without allocating.
@MainActor
enum InputPath {
    static func begin(_ name: StaticString) -> InputLatencyMonitor.Work? { InputLatencyMonitor.current?.beginWork(name) }

    static func end(_ work: InputLatencyMonitor.Work?) {
        guard let work else { return }
        InputLatencyMonitor.current?.endWork(work)
    }
}

/// The signposts of the monitor, in the app's subsystem under the category `input` and again under Points of Interest, which
/// is the only category Instruments' Points of Interest instrument shows.
private struct InputSignposts {
    struct Interval {
        let name: StaticString
        let input: OSSignpostIntervalState
        let interest: OSSignpostIntervalState
    }

    private let input = OSSignposter(subsystem: Log.subsystem, category: "input")
    private let interest = OSSignposter(logHandle: OSLog(subsystem: Log.subsystem, category: .pointsOfInterest))

    func begin(_ name: StaticString) -> Interval {
        Interval(
            name: name, input: input.beginInterval(name, id: input.makeSignpostID()),
            interest: interest.beginInterval(name, id: interest.makeSignpostID()))
    }

    func end(_ interval: Interval) {
        input.endInterval(interval.name, interval.input)
        interest.endInterval(interval.name, interval.interest)
    }

    /// An event reached the app `age` nanoseconds after it happened.
    func received(_ kind: InputKind, age: UInt64) {
        input.emitEvent("input event", "\(kind.label, privacy: .public) \(age / 1_000, privacy: .public) us late")
        interest.emitEvent("input event", "\(kind.label, privacy: .public) \(age / 1_000, privacy: .public) us late")
    }

    func stalled(_ stall: LoopStall) {
        let microseconds = stall.duration / 1_000
        input.emitEvent("main stall", "\(microseconds, privacy: .public) us")
        interest.emitEvent("main stall", "\(microseconds, privacy: .public) us")
    }
}

/// Appends the monitor's summary lines to the file the owner named.
enum LatencySummaryFile {
    static func append(_ line: String, to url: URL) {
        let text = "\(Date.now.formatted(.iso8601)) \(line)\n"
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            Log.input.error(
                "Couldn't write the latency summary (\(error.logKind, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }
}

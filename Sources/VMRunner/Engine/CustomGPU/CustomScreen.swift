import CoreGraphics
import VirtioGPU

/// The guest's cursor as the window draws it: where it is, the hot spot of its picture, and the picture, if it has one.
struct CursorState: Equatable {
    var x: UInt32
    var y: UInt32
    var hotX: UInt32
    var hotY: UInt32
    /// The cursor's picture in the guest's pixel format, or `nil` while the guest has none (it hid the cursor, or has not set one).
    var picture: ScanoutUpdate?
    /// Changes whenever an update sets or clears `picture`, so a view that kept a converted copy knows when to make another.
    var pictureGeneration: UInt64

    /// The cursor after `update`: a move keeps the picture and hot spot of the update before it.
    static func after(_ update: CursorUpdate, previous: Self?) -> Self {
        var picture = previous?.picture
        var generation = previous?.pictureGeneration ?? 0
        switch update.image {
        case .unchanged: break
        case .hidden:
            picture = nil
            generation += 1
        case .shown(let shown):
            picture = shown
            generation += 1
        }
        return Self(
            x: update.x, y: update.y, hotX: update.hotX, hotY: update.hotY, picture: picture, pictureGeneration: generation)
    }
}

/// What draws a `CustomScreen`: the view in the machine's window.
@MainActor
protocol ScreenPresenter: AnyObject {
    /// A new picture of the scanout: at most one per `CustomScreen.frameInterval`, and always the newest.
    func present(frame: ScanoutUpdate)
    /// The cursor moved, or its picture was set or cleared. `nil` before the guest's first cursor request.
    func present(cursor: CursorState?)
}

/// What the guest has drawn on a custom GPU's display: the newest picture of the scanout and the state of the cursor. The
/// device gives it each picture and cursor change on the main actor; the window that draws it attaches as the presenter.
///
/// A guest may flush many times a refresh (a scrolling console did 640 requests a second), and turning a picture into an image
/// costs a copy of every byte of it. The screen therefore hands the presenter one picture per `frameInterval` at most: the
/// first at once, the ones that follow within the interval as the newest of them when it has passed. It keeps the newest
/// picture for a presenter that comes later (full screen replaces the view), which then draws it without waiting. A screen with
/// no presenter, or no new picture, schedules nothing.
@MainActor
final class CustomScreen {
    /// One refresh of a 60 Hz display.
    nonisolated static let frameInterval = Duration.milliseconds(16)

    /// The size, in pixels, of the display the machine started with: what the guest's first display-information request answers.
    let displaySize: CGSize
    /// The newest picture of the scanout, or `nil` before the guest's first flush.
    private(set) var frame: ScanoutUpdate?
    /// The cursor, or `nil` before the guest's first cursor request.
    private(set) var cursor: CursorState?

    /// A registration for the size of each picture the guest draws; it ends when the registration is released.
    final class FrameObservation {
        fileprivate let handler: @MainActor (CGSize) -> Void

        fileprivate init(_ handler: @escaping @MainActor (CGSize) -> Void) {
            self.handler = handler
        }
    }

    private weak var presenter: (any ScreenPresenter)?
    private var observations: [() -> FrameObservation?] = []
    private var throttle: FrameThrottle
    private var tick: Task<Void, Never>?
    private let sleep: (Duration) async throws -> Void
    private let now: () -> UInt64
    private let interval: Duration

    init<C: Clock>(displaySize: CGSize, interval: Duration = frameInterval, clock: C) where C.Duration == Duration {
        self.displaySize = displaySize
        self.interval = interval
        throttle = FrameThrottle(intervalMilliseconds: UInt64(max(interval / .milliseconds(1), 1)))
        sleep = { try await clock.sleep(for: $0) }
        let start = clock.now
        now = { UInt64(max(start.duration(to: clock.now) / .milliseconds(1), 0)) }
    }

    convenience init(displaySize: CGSize) {
        self.init(displaySize: displaySize, clock: ContinuousClock())
    }

    isolated deinit {
        tick?.cancel()
    }

    /// The size of the picture the guest draws: the newest picture's, or before the first the size the machine started with.
    var pictureSize: CGSize {
        frame.map { CGSize(width: Int($0.width), height: Int($0.height)) } ?? displaySize
    }

    /// Calls `handler` with the size of every picture the guest flushes, each one, before the screen decides whether to draw it.
    /// The registration lasts as long as the returned object is held.
    func observeFrames(_ handler: @escaping @MainActor (CGSize) -> Void) -> AnyObject {
        let observation = FrameObservation(handler)
        observations.append { [weak observation] in observation }
        return observation
    }

    /// Makes `presenter` the one that draws, and gives it the newest picture and the cursor now. A presenter that was attached
    /// before is no longer called.
    func attach(_ presenter: some ScreenPresenter) {
        self.presenter = presenter
        tick?.cancel()
        tick = nil
        throttle = FrameThrottle(intervalMilliseconds: throttle.interval)
        if let frame, let ready = throttle.offer(frame, atMilliseconds: now()) { presenter.present(frame: ready) }
        presenter.present(cursor: cursor)
    }

    /// Ends `presenter`'s drawing, unless another presenter has replaced it.
    func detach(_ presenter: some ScreenPresenter) {
        guard self.presenter === presenter else { return }
        self.presenter = nil
    }

    func show(_ update: ScanoutUpdate) {
        frame = update
        notifyObservers(of: update)
        guard let presenter else { return }
        if let ready = throttle.offer(update, atMilliseconds: now()) {
            presenter.present(frame: ready)
        } else {
            scheduleTick()
        }
    }

    func show(_ update: CursorUpdate) {
        cursor = CursorState.after(update, previous: cursor)
        presenter?.present(cursor: cursor)
    }

    private func notifyObservers(of update: ScanoutUpdate) {
        guard !observations.isEmpty else { return }
        var live: [FrameObservation] = []
        observations.removeAll { observation in
            guard let observation = observation() else { return true }
            live.append(observation)
            return false
        }
        let size = CGSize(width: Int(update.width), height: Int(update.height))
        for observation in live { observation.handler(size) }
    }

    /// One wait at most is pending: it ends a full interval after the picture it was started for was kept back, by when the
    /// interval since the last picture shown has passed.
    private func scheduleTick() {
        guard tick == nil else { return }
        tick = Task { [weak self, sleep, interval] in
            try? await sleep(interval)
            guard !Task.isCancelled else { return }
            self?.intervalPassed()
        }
    }

    private func intervalPassed() {
        tick = nil
        if let ready = throttle.tick(atMilliseconds: now()) { presenter?.present(frame: ready) }
    }
}

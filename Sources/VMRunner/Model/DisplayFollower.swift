import CoreGraphics
import Foundation

/// A guest display whose size can be requested. `VZGraphicsDisplay` already has both members, so it conforms as it is.
protocol ResizableDisplay: AnyObject {
    var sizeInPixels: CGSize { get }
    func reconfigure(sizeInPixels: CGSize) throws
}

/// Keeps a guest's display at `scale` pixels per point of the view that shows it, with the view's aspect ratio.
///
/// This is the policy of the Linux guests' resize (macOS guests are resized by the framework): which size to ask for, when,
/// and what to do when the framework refuses. It owns no AppKit or Virtualization object, so tests drive it with a fake
/// display and a test clock.
///
/// - Sizes under `minimumPoints` are ignored, and a huge window is scaled down to the largest framebuffer the editor offers.
/// - A burst of sizes (a live resize) produces one request, for the last size, once the view has been quiet for
///   `quietPeriod`. Reporting the size the view already has changes nothing, so a view that lays out again and again at one
///   size cannot postpone the request forever.
/// - Nothing is requested during `hold`. The firmware reads the display once, early, and a request that lands before it
///   would replace the capped starting size (`StartDisplay`) with the window's full size.
/// - A request is skipped only while neither the target nor the size the display reports has changed since the last
///   successful request, so a display that moved by itself is asked again.
/// - A refused request is reported, forgotten and retried with a growing delay, `maximumRetries` times; the next change of
///   the view's size starts over.
@MainActor
final class DisplayFollower {
    /// What happened, for the log. Sizes are pixels unless the case says points.
    enum Event: Equatable, CustomStringConvertible {
        case released
        case ignored(points: CGSize)
        case noDisplay
        case skipped(target: CGSize)
        case requested(points: CGSize, target: CGSize, displayWas: CGSize)
        case refused(target: CGSize, errorKind: String, attempt: Int, retryIn: Duration?)

        var description: String {
            switch self {
            case .released: "hold over, requests allowed"
            case .ignored(let points): "view \(Self.text(points)) pt is too small to follow"
            case .noDisplay: "no graphics display to resize"
            case .skipped(let target): "display already \(Self.text(target)) px, nothing to ask"
            case .requested(let points, let target, let displayWas):
                "view \(Self.text(points)) pt: asked for \(Self.text(target)) px (display was \(Self.text(displayWas)) px)"
            case .refused(let target, let errorKind, let attempt, let retryIn):
                "refused \(Self.text(target)) px (\(errorKind)), attempt \(attempt), "
                    + (retryIn.map { "retrying in \($0)" } ?? "giving up until the view changes size")
            }
        }

        private static func text(_ size: CGSize) -> String { "\(Int(size.width))×\(Int(size.height))" }
    }

    /// Shortest side, in points, the guest is asked to follow.
    nonisolated static let minimumPoints: CGFloat = 64
    nonisolated static let quietPeriod = Duration.milliseconds(150)
    /// How long after a cold boot a Linux guest's display is left at its starting size, for the firmware.
    nonisolated static let firmwareHold = Duration.seconds(10)
    nonisolated static let maximumRetries = 5
    nonisolated static let firstRetryDelay = Duration.milliseconds(500)

    /// The framebuffer to ask for when the view is `view` points across, or `nil` when the view is too small to follow.
    nonisolated static func pixels(for view: CGSize, scale: Double) -> CGSize? {
        guard view.width.isFinite, view.height.isFinite, scale.isFinite, scale > 0,
            view.width >= minimumPoints, view.height >= minimumPoints
        else { return nil }
        var width = Double(view.width) * scale
        var height = Double(view.height) * scale
        let shrink = min(
            1, Double(EditorLimits.displayWidth.upperBound) / width, Double(EditorLimits.displayHeight.upperBound) / height)
        width *= shrink
        height *= shrink
        return CGSize(width: Int(width) & ~1, height: Int(height) & ~1)
    }

    private var scale: Double
    private var enabled: Bool
    private var viewSize: CGSize?
    private var released: Bool
    private var lastRequest: (target: CGSize, displayAfter: CGSize)?
    private var attempt = 0

    private let sleep: (Duration) async throws -> Void
    private let display: () -> (any ResizableDisplay)?
    private let report: (Event) -> Void
    private var debouncer: Debouncer<CGSize>?
    private var holdTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    init<C: Clock>(
        scale: Double, enabled: Bool, hold: Duration, clock: C, display: @escaping () -> (any ResizableDisplay)?,
        report: @escaping (Event) -> Void
    ) where C.Duration == Duration {
        self.scale = scale
        self.enabled = enabled
        self.display = display
        self.report = report
        sleep = { try await clock.sleep(for: $0) }
        released = hold <= .zero
        debouncer = Debouncer(quietPeriod: Self.quietPeriod, clock: clock) { [weak self] size in self?.apply(size) }
        guard !released else { return }
        holdTask = Task { [weak self, sleep] in
            try? await sleep(hold)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    isolated deinit {
        holdTask?.cancel()
        retryTask?.cancel()
    }

    /// Applies a change of scale or of whether the guest follows at all, and asks again for the current view size.
    func configure(scale: Double, enabled: Bool) {
        guard self.scale != scale || self.enabled != enabled else { return }
        self.scale = scale
        self.enabled = enabled
        lastRequest = nil
        if let viewSize { schedule(viewSize) }
    }

    func viewResized(to size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        schedule(size)
    }

    private func release() {
        released = true
        report(.released)
        if let viewSize { schedule(viewSize) }
    }

    private func schedule(_ size: CGSize) {
        guard enabled else { return }
        guard Self.pixels(for: size, scale: scale) != nil else {
            report(.ignored(points: size))
            return
        }
        attempt = 0
        retryTask?.cancel()
        guard released else { return }
        debouncer?.submit(size)
    }

    private func apply(_ size: CGSize) {
        guard let target = Self.pixels(for: size, scale: scale) else { return }
        guard let display = display() else {
            report(.noDisplay)
            return
        }
        let current = display.sizeInPixels
        if target == current || (lastRequest.map { $0.target == target && $0.displayAfter == current } ?? false) {
            lastRequest = (target, current)
            report(.skipped(target: target))
            return
        }
        report(.requested(points: size, target: target, displayWas: current))
        do {
            try display.reconfigure(sizeInPixels: target)
            lastRequest = (target, display.sizeInPixels)
            attempt = 0
        } catch {
            lastRequest = nil
            attempt += 1
            let delay = attempt <= Self.maximumRetries ? Self.firstRetryDelay * (1 << (attempt - 1)) : nil
            report(.refused(target: target, errorKind: error.logKind, attempt: attempt, retryIn: delay))
            if let delay { retry(size, after: delay) }
        }
    }

    private func retry(_ size: CGSize, after delay: Duration) {
        retryTask?.cancel()
        retryTask = Task { [weak self, sleep] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.apply(size)
        }
    }
}

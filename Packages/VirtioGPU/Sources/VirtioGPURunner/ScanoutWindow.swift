import AppKit
import VirtioGPURunnerCore

/// The runner's own window, showing the scanout as the contents of a layer, at most 30 times a second. It is made at the
/// first picture, sized to it, and never takes keys or clicks to the guest (the machine has no keyboard or pointer).
@MainActor
final class ScanoutWindow: ScanoutSink {
    private var window: NSWindow?
    private var throttle = FrameThrottle(intervalMilliseconds: 33)

    func show(_ update: ScanoutUpdate, atMilliseconds now: UInt64) {
        if let frame = throttle.offer(update, atMilliseconds: now) { present(frame) }
    }

    func tick(atMilliseconds now: UInt64) {
        if let frame = throttle.tick(atMilliseconds: now) { present(frame) }
    }

    func finish() {
        if let frame = throttle.drain() { present(frame) }
    }

    private func present(_ update: ScanoutUpdate) {
        guard let image = ScanoutPicture.cgImage(update) else { return }
        let view = window?.contentView ?? makeWindow(width: Int(update.width), height: Int(update.height))
        view.layer?.contents = image
    }

    private func makeWindow(width: Int, height: Int) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Virtio GPU scanout"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        window.contentView = view
        window.center()
        window.orderFront(nil)
        self.window = window
        return view
    }
}

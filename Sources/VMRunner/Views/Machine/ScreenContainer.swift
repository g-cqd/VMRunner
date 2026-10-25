import AppKit

/// Hosts the view that shows a machine's screen without exposing its intrinsic size, which would otherwise resize the window
/// to the guest framebuffer. The framework's view and the custom GPU's view are hosted the same way: pinned to the four edges,
/// the keyboard given once, the container's size reported.
class ScreenContainer: NSView {
    /// The view that shows the screen, pinned to the container's edges.
    let hosted: NSView
    var onLayout: ((CGSize) -> Void)?
    private var gaveKeyboard = false

    init(hosting content: NSView) {
        hosted = content
        super.init(frame: .zero)
        // The framework's view turns off `translatesAutoresizingMaskIntoConstraints` itself, so an autoresizing mask does
        // nothing for it: inside a container that Auto Layout sizes (SwiftUI's hosting does) the view stayed at the size of
        // its first layout. The picture was then scaled to that oversized view and cropped by the window. Pin the four edges.
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ScreenContainer is created in code only") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        report("layout")
    }

    /// AppKit lays a view out when it decides to; the size is also reported as soon as the frame changes, so a resize that
    /// does not reach `layout()` still reaches the guest.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        report("frame")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        DisplayDiagnostics.note("backing properties changed: \(windowDescription)")
    }

    /// The screen's view takes the keyboard the first time the display is in a window, so typing reaches the guest without a
    /// click first. Only once: a later move must not take the keyboard from wherever the user put it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // AppKit declares `window` unowned(unsafe); it is alive for the duration of this callback and not kept.
        guard !gaveKeyboard, let window = unsafe self.window else { return }
        gaveKeyboard = window.makeFirstResponder(hosted)
    }

    private func report(_ cause: String) {
        let containerSize = DisplayDiagnostics.text(bounds.size)
        let viewSize = DisplayDiagnostics.text(hosted.frame.size)
        DisplayDiagnostics.note("\(cause): container \(containerSize) pt, machine view \(viewSize) pt, \(windowDescription)")
        onLayout?(bounds.size)
    }

    private var windowDescription: String {
        // AppKit declares `window` unowned(unsafe); it is alive for the duration of this call and not kept.
        guard let window = unsafe self.window else { return "no window" }
        return "window \(DisplayDiagnostics.text(window.frame.size)) pt, backing scale \(window.backingScaleFactor), "
            + "full screen \(window.styleMask.contains(.fullScreen))"
    }
}

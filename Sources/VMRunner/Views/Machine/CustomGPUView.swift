import AppKit
import VirtioGPU

/// Shows the picture the guest draws on a custom GPU, and its cursor. The picture is the contents of the view's layer, scaled to
/// fit with its aspect ratio over black; the cursor is a layer above it, placed where the guest put it. The view takes the
/// keyboard when it is in a window, like the framework's own view does, but passes nothing to the guest: input for such a
/// machine has no path yet, and the view swallows key presses so that the system does not beep at each of them.
@MainActor
final class CustomGPUView: NSView, ScreenPresenter {
    private let cursorLayer = CALayer()
    private weak var screen: CustomScreen?
    /// The size, in guest pixels, of the picture on show; zero before the first one.
    private(set) var pictureSize = CGSize.zero
    private var cursor: CursorState?
    private var cursorGeneration: UInt64?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.contentsGravity = .resizeAspect
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CustomGPUView is created in code only") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        placeCursor()
    }

    /// Draws `screen`, and no longer the one drawn before.
    func show(_ screen: CustomScreen) {
        guard self.screen !== screen else { return }
        self.screen?.detach(self)
        self.screen = screen
        screen.attach(self)
    }

    /// Stops drawing: the view is going away.
    func detach() {
        screen?.detach(self)
        screen = nil
    }

    func present(frame: ScanoutUpdate) {
        guard let image = ScreenPicture.cgImage(frame) else { return }
        layer?.contents = image
        pictureSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        placeCursor()
    }

    func present(cursor: CursorState?) {
        self.cursor = cursor
        if cursor?.pictureGeneration != cursorGeneration {
            cursorGeneration = cursor?.pictureGeneration
            let image = cursor?.picture.flatMap { ScreenPicture.cgImage($0, alpha: true) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image
            CATransaction.commit()
        }
        placeCursor()
    }

    /// The layer's origin is its bottom left corner; the placement's is the top left.
    private func placeCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = cursor.map { ScreenPlacement.cursorRect($0, picture: pictureSize, in: bounds.size) } ?? .zero
        guard rect != .zero, cursorLayer.contents != nil else {
            cursorLayer.isHidden = true
            return
        }
        cursorLayer.frame = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        cursorLayer.isHidden = false
    }
}

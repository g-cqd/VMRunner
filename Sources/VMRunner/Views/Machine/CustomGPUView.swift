import AppKit
import VirtioGPU

/// Shows the picture the guest draws on a custom GPU, and its cursor. The picture is the contents of the view's layer, scaled to
/// fit with its aspect ratio over black; the cursor is a layer above it, placed where the guest put it. The view takes the
/// keyboard when it is in a window, like the framework's own view does, and passes every key, pointer and scroll event to the
/// machine's input surface (`CustomGPUView+Input.swift`); without one it swallows them, so that the system does not beep at
/// each key press.
@MainActor
final class CustomGPUView: NSView, ScreenPresenter {
    private let cursorLayer = CALayer()
    private weak var screen: CustomScreen?
    /// The size, in guest pixels, of the picture on show; zero before the first one.
    private(set) var pictureSize = CGSize.zero
    private var cursor: CursorState?
    private var cursorGeneration: UInt64?
    /// Where this view's events go; `nil` until the view is given a surface.
    private(set) var input: (any GuestInputSurface)?

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

    override func layout() {
        super.layout()
        placeCursor()
        placeInput()
    }

    /// Draws `screen`, and no longer the one drawn before.
    func show(_ screen: CustomScreen) {
        guard self.screen !== screen else { return }
        self.screen?.detach(self)
        self.screen = screen
        screen.attach(self)
    }

    /// Passes this view's events to `input`, and no longer to the surface it had.
    func use(_ input: any GuestInputSurface) {
        guard self.input !== input else { return }
        self.input?.detach(from: self)
        self.input = input
        input.attach(to: self)
        placeInput()
    }

    /// Stops drawing and passing events: the view is going away.
    func detach() {
        screen?.detach(self)
        screen = nil
        input?.detach(from: self)
        input = nil
    }

    func present(frame: ScanoutUpdate) {
        guard let image = ScreenPicture.cgImage(frame) else { return }
        layer?.contents = image
        pictureSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        placeCursor()
        placeInput()
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
        cursorLayer.frame = ScreenPlacement.flipped(rect, in: bounds.size)
        cursorLayer.isHidden = false
    }

    /// Tells the input surface where the picture sits.
    private func placeInput() {
        input?.placePicture(ScreenPlacement.pictureRect(picture: pictureSize, in: bounds.size), in: bounds.size)
    }
}

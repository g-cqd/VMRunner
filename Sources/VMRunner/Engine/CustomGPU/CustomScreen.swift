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

/// What the guest has drawn on a custom GPU's display: the newest picture of the scanout and the state of the cursor. The
/// device gives it each picture and cursor change on the main actor; the window reads it.
@MainActor
final class CustomScreen {
    /// The size, in pixels, of the display the guest was told to use: what its display-information request answers.
    private(set) var displaySize: CGSize
    /// The newest picture of the scanout, or `nil` before the guest's first flush.
    private(set) var frame: ScanoutUpdate?
    /// The cursor, or `nil` before the guest's first cursor request.
    private(set) var cursor: CursorState?

    init(displaySize: CGSize) {
        self.displaySize = displaySize
    }

    func show(_ update: ScanoutUpdate) {
        frame = update
    }

    func show(_ update: CursorUpdate) {
        cursor = CursorState.after(update, previous: cursor)
    }
}

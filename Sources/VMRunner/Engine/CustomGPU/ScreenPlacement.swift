import CoreGraphics
import VirtioGPU

/// Where the guest's picture and cursor sit in the view that shows them. The picture is shown at the largest size that fits the
/// view with its aspect ratio, centered; every rectangle here has its origin at the top left of the view.
enum ScreenPlacement {
    /// The rectangle the picture occupies, or `.zero` when either size is empty.
    static func pictureRect(picture: CGSize, in view: CGSize) -> CGRect {
        guard picture.width > 0, picture.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let scale = min(view.width / picture.width, view.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// `rect`, which has its origin at the top left of a view of `size`, with its origin at the view's bottom left (the origin of
    /// a layer and of an `NSView` that is not flipped).
    static func flipped(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The rectangle of the cursor's image: its hot spot sits on the cursor's position, and one guest pixel is as large as one
    /// pixel of the picture. `.zero` when the cursor has no picture or the display is empty.
    static func cursorRect(_ cursor: CursorState, picture: CGSize, in view: CGSize) -> CGRect {
        let area = pictureRect(picture: picture, in: view)
        guard let image = cursor.picture, area != .zero else { return .zero }
        let scale = area.width / picture.width
        return CGRect(
            x: area.minX + (CGFloat(cursor.x) - CGFloat(cursor.hotX)) * scale,
            y: area.minY + (CGFloat(cursor.y) - CGFloat(cursor.hotY)) * scale,
            width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}

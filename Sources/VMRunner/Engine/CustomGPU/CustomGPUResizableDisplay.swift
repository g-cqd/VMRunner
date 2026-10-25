import CoreGraphics

/// The custom GPU's display as `DisplayFollower` resizes it, in place of the framework's `VZGraphicsDisplay`.
///
/// - `sizeInPixels` is the size of the picture the guest last drew (the size the machine started with before its first), not the
///   size it was asked for: the guest has not changed its display until it draws at the new size, as the framework's display
///   does not either, and a follower that read the requested size back would take every request for answered.
/// - A request is passed to the device, which answers the guest's next display-information request with the new size and tells
///   the guest to ask for it. The device refuses a size it cannot report (zero, past its limits, a picture too big for one
///   resource), and so does this display; a size that is not whole pixels is refused before the device is asked.
/// - The end of a reconfiguration is the first picture the guest flushes at the size that was asked for, which is all the device
///   sees of the guest using a size (it sees no setting of the display by the framework). It is reported once per request.
@MainActor
final class CustomGPUResizableDisplay: ResizableDisplay {
    /// The device or the size refuses the request.
    struct Refused: Error {}

    private let source: any CustomDisplaySource
    /// The size of the last request, until the guest draws at it.
    private var awaited: CGSize?

    init(source: any CustomDisplaySource) {
        self.source = source
    }

    var sizeInPixels: CGSize { source.screen.pictureSize }

    func reconfigure(sizeInPixels size: CGSize) throws {
        guard let width = UInt32(exactly: size.width), let height = UInt32(exactly: size.height),
            source.requestDisplaySize(width: width, height: height)
        else { throw Refused() }
        awaited = size
    }

    func observeReconfigurationEnd(_ handler: @escaping @MainActor () -> Void) -> AnyObject {
        source.screen.observeFrames { [weak self] size in
            guard let self, awaited == size else { return }
            awaited = nil
            handler()
        }
    }
}

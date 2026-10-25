/// The bounds the device puts on what a guest may ask of it. The guest is untrusted: every count, size and length it sends is
/// checked against these before anything is allocated or copied.
package struct GPULimits: Equatable, Sendable {
    /// How many 2D resources may exist at once; one more is refused with an out-of-memory answer.
    package var maxResources = 256
    /// The largest host copy of one resource, in bytes (width × height × 4): 64 MiB, a 4096 × 4096 surface.
    package var maxResourceBytes = 64 << 20
    /// The host copies of all resources together, in bytes.
    package var maxTotalResourceBytes = 256 << 20
    /// The most guest memory pieces one resource's backing may list: a 64 MiB surface in 4 KiB pages.
    package var maxBackingEntries = 16_384
    /// The most rows a transfer of a rectangle narrower than its resource may copy. Such a transfer is read one span per row,
    /// so its cost grows with its rows rather than its bytes. The Linux driver's scanouts are at most 8192 rows high.
    package var maxTransferRows = 8192
    /// The size of the one display the device reports until the host changes it.
    package var displayWidth: UInt32 = 1280
    package var displayHeight: UInt32 = 800
    /// The longest side the host may give the display, in pixels: the Linux driver's own bound. With `maxResourceBytes` it
    /// allows a 4K or a 5K display (a 5120 × 2880 picture is 56 MiB) and refuses an 8K one (7680 × 4320 is 127 MiB).
    package var maxDisplaySide: UInt32 = 8192
    /// The longest side of a cursor image the host is given. The spec's cursor is 64 × 64; a larger resource is treated as
    /// no cursor, so the guest cannot make the host copy a picture of any size on each cursor update.
    package var maxCursorSide: UInt32 = 256

    package init() {}

    /// Whether a display of this size may be reported: no side is zero or above `maxDisplaySide`, and a picture of it fits one
    /// resource, which is what the guest's driver allocates for the scanout.
    package func allowsDisplay(width: UInt32, height: UInt32) -> Bool {
        guard width > 0, height > 0, width <= maxDisplaySide, height <= maxDisplaySide else { return false }
        return Int(width) * Int(height) * GPUPixelFormat.bytesPerPixel <= maxResourceBytes
    }

    /// `width` × `height` made to satisfy `allowsDisplay`: each side at least 1 and at most `maxDisplaySide`, and when the picture
    /// is still too large for one resource, both sides scaled down together, which keeps the aspect ratio.
    package func fittingDisplay(width: UInt32, height: UInt32) -> (width: UInt32, height: UInt32) {
        var fitted = (width: min(max(width, 1), maxDisplaySide), height: min(max(height, 1), maxDisplaySide))
        let pixels = Double(fitted.width) * Double(fitted.height)
        let room = Double(maxResourceBytes / GPUPixelFormat.bytesPerPixel)
        if pixels > room {
            let scale = (room / pixels).squareRoot()
            fitted = (width: max(UInt32(Double(fitted.width) * scale), 1), height: max(UInt32(Double(fitted.height) * scale), 1))
        }
        return fitted
    }

    /// The longest request the device reads: an attach-backing header followed by the most entries it accepts.
    package var maxCommandBytes: Int { GPUWireSize.attachBacking + GPUWireSize.memoryEntry * maxBackingEntries }
}

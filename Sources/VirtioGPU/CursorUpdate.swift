/// What a cursor request changed, for the host to draw: where the cursor is and the hot spot of its image, and the image
/// when the request set one.
package struct CursorUpdate: Equatable, Sendable {
    /// What the request did to the cursor's image.
    package enum Image: Equatable, Sendable {
        /// A move: the image of the last update stays.
        case unchanged
        /// An update that names no usable resource: the guest hid the cursor.
        case hidden
        /// An update: the resource as it is now, in the resource's own pixel format.
        case shown(ScanoutUpdate)
    }

    package let x: UInt32
    package let y: UInt32
    package let hotX: UInt32
    package let hotY: UInt32
    package let image: Image
}

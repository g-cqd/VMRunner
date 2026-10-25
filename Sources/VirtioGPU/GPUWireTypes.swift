/// The sizes of the 2D requests and answers of the virtio GPU device, in bytes, as the virtio specification lays them out
/// (packed, little-endian).
package enum GPUWireSize {
    package static let header = 24
    package static let getDisplayInfo = 24
    package static let resourceCreate2D = 40
    package static let resourceUnref = 32
    package static let setScanout = 48
    package static let resourceFlush = 48
    package static let transferToHost2D = 56
    /// The fixed part of an attach-backing request; its memory entries follow.
    package static let attachBacking = 32
    package static let memoryEntry = 16
    package static let detachBacking = 32
    package static let getEDID = 32
    package static let cursor = 56
    /// A display-information answer: the header and 16 modes of 24 bytes.
    package static let displayInfo = 408
    /// The number of modes a display-information answer always carries.
    package static let displayModes = 16
}

/// The request types the device decodes. Any other value (capability sets, blobs, UUIDs, 3D) is answered as unsupported.
package enum GPUCommandType: UInt32, Sendable, CaseIterable {
    case getDisplayInfo = 0x0100
    case resourceCreate2D = 0x0101
    case resourceUnref = 0x0102
    case setScanout = 0x0103
    case resourceFlush = 0x0104
    case transferToHost2D = 0x0105
    case resourceAttachBacking = 0x0106
    case resourceDetachBacking = 0x0107
    case getEDID = 0x010a
    case updateCursor = 0x0300
    case moveCursor = 0x0301

    /// Whether the request belongs on the cursor queue rather than the control queue.
    package var isCursor: Bool { self == .updateCursor || self == .moveCursor }
}

/// The answer types the device writes.
package enum GPUResponseType: UInt32, Sendable, CaseIterable {
    case okNoData = 0x1100
    case okDisplayInfo = 0x1101
    case errUnspec = 0x1200
    case errOutOfMemory = 0x1201
    case errInvalidScanoutID = 0x1202
    case errInvalidResourceID = 0x1203
    case errInvalidContextID = 0x1204
    case errInvalidParameter = 0x1205
}

/// The header that starts every request and every answer.
package struct GPUControlHeader: Equatable, Sendable {
    /// The guest asks to be told, through the answer, that this request's effect is complete.
    package static let fenceFlag: UInt32 = 1 << 0
    /// The fence belongs to the ring named by `ringIndex`.
    package static let ringIndexFlag: UInt32 = 1 << 1

    package var type: UInt32
    package var flags: UInt32
    package var fenceID: UInt64
    package var contextID: UInt32
    package var ringIndex: UInt8

    package init(type: UInt32, flags: UInt32 = 0, fenceID: UInt64 = 0, contextID: UInt32 = 0, ringIndex: UInt8 = 0) {
        self.type = type
        self.flags = flags
        self.fenceID = fenceID
        self.contextID = contextID
        self.ringIndex = ringIndex
    }

    /// The header used to answer a request too short to carry one: no flags, no fence.
    package static let unreadable = Self(type: 0)
}

/// A rectangle in a resource's or a scanout's pixels.
package struct GPURect: Equatable, Sendable {
    package var x: UInt32
    package var y: UInt32
    package var width: UInt32
    package var height: UInt32

    package init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Whether the rectangle lies inside a surface of `width` × `height`, computed without overflow.
    package func fits(width surfaceWidth: UInt32, height surfaceHeight: UInt32) -> Bool {
        UInt64(x) + UInt64(width) <= UInt64(surfaceWidth) && UInt64(y) + UInt64(height) <= UInt64(surfaceHeight)
    }

    /// Whether the two rectangles share at least one pixel.
    package func intersects(_ other: Self) -> Bool {
        UInt64(x) < UInt64(other.x) + UInt64(other.width) && UInt64(other.x) < UInt64(x) + UInt64(width)
            && UInt64(y) < UInt64(other.y) + UInt64(other.height) && UInt64(other.y) < UInt64(y) + UInt64(height)
    }
}

/// One piece of guest memory backing a resource.
package struct GPUMemoryEntry: Equatable, Sendable {
    package var address: UInt64
    package var length: UInt32

    package init(address: UInt64, length: UInt32) {
        self.address = address
        self.length = length
    }
}

/// A cursor request: where the cursor is, and for an update, its image and hot spot.
package struct GPUCursor: Equatable, Sendable {
    package var scanoutID: UInt32
    package var x: UInt32
    package var y: UInt32
    package var resourceID: UInt32
    package var hotX: UInt32
    package var hotY: UInt32

    package init(scanoutID: UInt32, x: UInt32, y: UInt32, resourceID: UInt32 = 0, hotX: UInt32 = 0, hotY: UInt32 = 0) {
        self.scanoutID = scanoutID
        self.x = x
        self.y = y
        self.resourceID = resourceID
        self.hotX = hotX
        self.hotY = hotY
    }
}

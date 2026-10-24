/// The sizes of the 2D requests and answers of the virtio GPU device, in bytes, as the virtio specification lays them out
/// (packed, little-endian).
public enum GPUWireSize {
    public static let header = 24
    public static let getDisplayInfo = 24
    public static let resourceCreate2D = 40
    public static let resourceUnref = 32
    public static let setScanout = 48
    public static let resourceFlush = 48
    public static let transferToHost2D = 56
    /// The fixed part of an attach-backing request; its memory entries follow.
    public static let attachBacking = 32
    public static let memoryEntry = 16
    public static let detachBacking = 32
    public static let getEDID = 32
    public static let cursor = 56
    /// A display-information answer: the header and 16 modes of 24 bytes.
    public static let displayInfo = 408
    /// The number of modes a display-information answer always carries.
    public static let displayModes = 16
}

/// The request types the device decodes. Any other value (capability sets, blobs, UUIDs, 3D) is answered as unsupported.
public enum GPUCommandType: UInt32, Sendable, CaseIterable {
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
    public var isCursor: Bool { self == .updateCursor || self == .moveCursor }
}

/// The answer types the device writes.
public enum GPUResponseType: UInt32, Sendable, CaseIterable {
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
public struct GPUControlHeader: Equatable, Sendable {
    /// The guest asks to be told, through the answer, that this request's effect is complete.
    public static let fenceFlag: UInt32 = 1 << 0
    /// The fence belongs to the ring named by `ringIndex`.
    public static let ringIndexFlag: UInt32 = 1 << 1

    public var type: UInt32
    public var flags: UInt32
    public var fenceID: UInt64
    public var contextID: UInt32
    public var ringIndex: UInt8

    public init(type: UInt32, flags: UInt32 = 0, fenceID: UInt64 = 0, contextID: UInt32 = 0, ringIndex: UInt8 = 0) {
        self.type = type
        self.flags = flags
        self.fenceID = fenceID
        self.contextID = contextID
        self.ringIndex = ringIndex
    }

    /// The header used to answer a request too short to carry one: no flags, no fence.
    public static let unreadable = Self(type: 0)
}

/// A rectangle in a resource's or a scanout's pixels.
public struct GPURect: Equatable, Sendable {
    public var x: UInt32
    public var y: UInt32
    public var width: UInt32
    public var height: UInt32

    public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Whether the rectangle lies inside a surface of `width` × `height`, computed without overflow.
    public func fits(width surfaceWidth: UInt32, height surfaceHeight: UInt32) -> Bool {
        UInt64(x) + UInt64(width) <= UInt64(surfaceWidth) && UInt64(y) + UInt64(height) <= UInt64(surfaceHeight)
    }

    /// Whether the two rectangles share at least one pixel.
    public func intersects(_ other: Self) -> Bool {
        UInt64(x) < UInt64(other.x) + UInt64(other.width) && UInt64(other.x) < UInt64(x) + UInt64(width)
            && UInt64(y) < UInt64(other.y) + UInt64(other.height) && UInt64(other.y) < UInt64(y) + UInt64(height)
    }
}

/// One piece of guest memory backing a resource.
public struct GPUMemoryEntry: Equatable, Sendable {
    public var address: UInt64
    public var length: UInt32

    public init(address: UInt64, length: UInt32) {
        self.address = address
        self.length = length
    }
}

/// A cursor request: where the cursor is, and for an update, its image and hot spot.
public struct GPUCursor: Equatable, Sendable {
    public var scanoutID: UInt32
    public var x: UInt32
    public var y: UInt32
    public var resourceID: UInt32
    public var hotX: UInt32
    public var hotY: UInt32

    public init(scanoutID: UInt32, x: UInt32, y: UInt32, resourceID: UInt32 = 0, hotX: UInt32 = 0, hotY: UInt32 = 0) {
        self.scanoutID = scanoutID
        self.x = x
        self.y = y
        self.resourceID = resourceID
        self.hotX = hotX
        self.hotY = hotY
    }
}

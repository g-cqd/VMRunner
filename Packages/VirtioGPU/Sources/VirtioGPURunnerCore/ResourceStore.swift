/// The 32-bit pixel formats a 2D resource may have; any other value is refused when the resource is created.
public enum GPUPixelFormat: UInt32, Sendable, CaseIterable {
    case b8g8r8a8 = 1
    case b8g8r8x8 = 2
    case a8r8g8b8 = 3
    case x8r8g8b8 = 4
    case r8g8b8a8 = 67
    case x8b8g8r8 = 68
    case a8b8g8r8 = 121
    case r8g8b8x8 = 134

    public static let bytesPerPixel = 4
}

/// A 2D resource: its host copy of the pixels, and the guest memory they are transferred from.
public struct GPUResource: Equatable, Sendable {
    public let id: UInt32
    public let format: GPUPixelFormat
    public let width: UInt32
    public let height: UInt32
    /// `width × height × 4` bytes, rows `stride` apart.
    public internal(set) var pixels: [UInt8]
    public internal(set) var backing: BackingLayout?

    public var stride: Int { Int(width) * GPUPixelFormat.bytesPerPixel }
}

/// The device's 2D resources, under `GPULimits`. Every operation answers with the response type the guest gets: `okNoData`
/// when it was done, an error otherwise, and an operation that fails changes nothing.
public struct ResourceStore: Sendable {
    public let limits: GPULimits
    private var resources: [UInt32: GPUResource] = [:]
    /// The bytes of every resource's host copy together.
    public private(set) var totalBytes = 0

    public init(limits: GPULimits) {
        self.limits = limits
    }

    public var count: Int { resources.count }
    public var isEmpty: Bool { resources.isEmpty }

    public func resource(_ id: UInt32) -> GPUResource? {
        resources[id]
    }

    /// Creates a zero-filled resource. The size is computed with overflow checks and held against the limits before the
    /// host copy is allocated.
    public mutating func create2D(resourceID id: UInt32, format: UInt32, width: UInt32, height: UInt32) -> GPUResponseType {
        guard id != 0, resources[id] == nil else { return .errInvalidResourceID }
        guard let format = GPUPixelFormat(rawValue: format), width > 0, height > 0 else { return .errInvalidParameter }
        let (pixels, wide) = Int(width).multipliedReportingOverflow(by: Int(height))
        let (bytes, overflow) = pixels.multipliedReportingOverflow(by: GPUPixelFormat.bytesPerPixel)
        guard !wide, !overflow, bytes <= limits.maxResourceBytes else { return .errOutOfMemory }
        guard resources.count < limits.maxResources, bytes <= limits.maxTotalResourceBytes - totalBytes else { return .errOutOfMemory }
        resources[id] = GPUResource(
            id: id, format: format, width: width, height: height, pixels: [UInt8](repeating: 0, count: bytes), backing: nil)
        totalBytes += bytes
        return .okNoData
    }

    public mutating func unref(_ id: UInt32) -> GPUResponseType {
        guard let removed = resources.removeValue(forKey: id) else { return .errInvalidResourceID }
        totalBytes -= removed.pixels.count
        return .okNoData
    }

    public mutating func attachBacking(_ id: UInt32, entries: [GPUMemoryEntry]) -> GPUResponseType {
        guard var resource = resources[id] else { return .errInvalidResourceID }
        guard resource.backing == nil else { return .errUnspec }
        guard entries.count <= limits.maxBackingEntries, let layout = BackingLayout(entries: entries) else { return .errInvalidParameter }
        resource.backing = layout
        resources[id] = resource
        return .okNoData
    }

    public mutating func detachBacking(_ id: UInt32) -> GPUResponseType {
        guard var resource = resources[id] else { return .errInvalidResourceID }
        guard resource.backing != nil else { return .errUnspec }
        resource.backing = nil
        resources[id] = resource
        return .okNoData
    }

    /// Copies `rect` of the resource from its backing. As the guest's driver lays it out, `offset` is where the rectangle's
    /// first pixel is in the backing (it already counts `y × stride + x × 4`), and each next row is `stride` further on.
    /// Every row is read into a temporary copy first; the host copy is written only once all of them were read, so a read
    /// that fails leaves the resource as it was.
    public mutating func transferToHost2D(resourceID id: UInt32, rect: GPURect, offset: UInt64, memory: some GuestMemoryReader)
        -> GPUResponseType
    {
        guard id != 0, var resource = resources[id] else { return .errInvalidResourceID }
        guard rect.fits(width: resource.width, height: resource.height) else { return .errInvalidParameter }
        guard let backing = resource.backing else { return .errUnspec }
        guard rect.width > 0, rect.height > 0 else { return .okNoData }
        let rowBytes = Int(rect.width) * GPUPixelFormat.bytesPerPixel
        let stride = UInt64(resource.stride)
        var rows: [UInt8] = []
        rows.reserveCapacity(rowBytes * Int(rect.height))
        for row in 0..<UInt64(rect.height) {
            let (skip, wide) = row.multipliedReportingOverflow(by: stride)
            let (start, overflow) = offset.addingReportingOverflow(skip)
            guard !wide, !overflow, let pieces = backing.pieces(offset: start, length: UInt64(rowBytes)) else {
                return .errInvalidParameter
            }
            for piece in pieces {
                guard let bytes = memory.copyBytes(atPhysicalAddress: piece.address, count: piece.count), bytes.count == piece.count
                else { return .errUnspec }
                rows.append(contentsOf: bytes)
            }
        }
        resources[id] = nil
        for row in 0..<Int(rect.height) {
            let destination = (Int(rect.y) + row) * resource.stride + Int(rect.x) * GPUPixelFormat.bytesPerPixel
            resource.pixels.replaceSubrange(destination..<destination + rowBytes, with: rows[row * rowBytes..<(row + 1) * rowBytes])
        }
        resources[id] = resource
        return .okNoData
    }

    /// Drops every resource, as a device reset does.
    public mutating func removeAll() {
        resources.removeAll()
        totalBytes = 0
    }
}

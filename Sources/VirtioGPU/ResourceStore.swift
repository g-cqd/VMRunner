/// The 32-bit pixel formats a 2D resource may have; any other value is refused when the resource is created.
package enum GPUPixelFormat: UInt32, Sendable, CaseIterable {
    case b8g8r8a8 = 1
    case b8g8r8x8 = 2
    case a8r8g8b8 = 3
    case x8r8g8b8 = 4
    case r8g8b8a8 = 67
    case x8b8g8r8 = 68
    case a8b8g8r8 = 121
    case r8g8b8x8 = 134

    package static let bytesPerPixel = 4
}

/// A 2D resource: its host copy of the pixels, and the guest memory they are transferred from.
package struct GPUResource: Equatable, Sendable {
    package let id: UInt32
    package let format: GPUPixelFormat
    package let width: UInt32
    package let height: UInt32
    /// `width × height × 4` bytes, rows `stride` apart.
    package internal(set) var pixels: [UInt8]
    package internal(set) var backing: BackingLayout?

    package var stride: Int { Int(width) * GPUPixelFormat.bytesPerPixel }
}

/// The device's 2D resources, under `GPULimits`. Every operation answers with the response type the guest gets: `okNoData`
/// when it was done, an error otherwise, and an operation that fails changes nothing.
package struct ResourceStore: Sendable {
    package let limits: GPULimits
    private var resources: [UInt32: GPUResource] = [:]
    /// The bytes of every resource's host copy together.
    package private(set) var totalBytes = 0

    package init(limits: GPULimits) {
        self.limits = limits
    }

    package var count: Int { resources.count }
    package var isEmpty: Bool { resources.isEmpty }

    package func resource(_ id: UInt32) -> GPUResource? {
        resources[id]
    }

    /// Creates a zero-filled resource. The size is computed with overflow checks and held against the limits before the
    /// host copy is allocated.
    package mutating func create2D(resourceID id: UInt32, format: UInt32, width: UInt32, height: UInt32) -> GPUResponseType {
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

    package mutating func unref(_ id: UInt32) -> GPUResponseType {
        guard let removed = resources.removeValue(forKey: id) else { return .errInvalidResourceID }
        totalBytes -= removed.pixels.count
        return .okNoData
    }

    package mutating func attachBacking(_ id: UInt32, entries: [GPUMemoryEntry]) -> GPUResponseType {
        guard var resource = resources[id] else { return .errInvalidResourceID }
        guard resource.backing == nil else { return .errUnspec }
        guard entries.count <= limits.maxBackingEntries, let layout = BackingLayout(entries: entries) else { return .errInvalidParameter }
        resource.backing = layout
        resources[id] = resource
        return .okNoData
    }

    package mutating func detachBacking(_ id: UInt32) -> GPUResponseType {
        guard var resource = resources[id] else { return .errInvalidResourceID }
        guard resource.backing != nil else { return .errUnspec }
        resource.backing = nil
        resources[id] = resource
        return .okNoData
    }

    /// Copies `rect` of the resource from its backing. As the guest's driver lays it out, `offset` is where the rectangle's
    /// first pixel is in the backing (it already counts `y × stride + x × 4`), and each next row is `stride` further on.
    /// The bytes are staged in one buffer made once, and the host copy is written only once all of them were read, so a read
    /// that fails leaves the resource as it was. The rows of a rectangle as wide as the resource follow each other in the
    /// backing, so they are one span: its pieces are listed once and each piece is copied once, however many rows there are.
    /// A narrower rectangle is read one span per row, and is refused above `GPULimits.maxTransferRows` rows: its cost grows
    /// with its rows, not with its bytes.
    package mutating func transferToHost2D(resourceID id: UInt32, rect: GPURect, offset: UInt64, memory: some GuestMemoryReader)
        -> GPUResponseType
    {
        guard id != 0, var resource = resources[id] else { return .errInvalidResourceID }
        guard rect.fits(width: resource.width, height: resource.height) else { return .errInvalidParameter }
        guard let backing = resource.backing else { return .errUnspec }
        guard rect.width > 0, rect.height > 0 else { return .okNoData }
        let spans = Spans(rect: rect, stride: resource.stride)
        guard spans.count == 1 || spans.count <= limits.maxTransferRows else { return .errInvalidParameter }
        let staged: [UInt8]
        do {
            staged = try Self.stage(spans, from: backing, at: offset, memory: memory)
        } catch {
            return error.responseType
        }
        resources[id] = nil
        let origin = Int(rect.y) * resource.stride + Int(rect.x) * GPUPixelFormat.bytesPerPixel
        for span in 0..<spans.count {
            let destination = origin + span * resource.stride
            resource.pixels.replaceSubrange(
                destination..<destination + spans.bytes, with: staged[span * spans.bytes..<(span + 1) * spans.bytes])
        }
        resources[id] = resource
        return .okNoData
    }

    /// How a transfer's rectangle splits into runs that are contiguous in the backing: a rectangle as wide as the resource is
    /// one run of all its rows, a narrower one has a run per row, each `stride` after the last.
    private struct Spans {
        let count: Int
        let bytes: Int
        let stride: Int

        init(rect: GPURect, stride: Int) {
            let rowBytes = Int(rect.width) * GPUPixelFormat.bytesPerPixel
            self.stride = stride
            (count, bytes) = rowBytes == stride ? (1, rowBytes * Int(rect.height)) : (Int(rect.height), rowBytes)
        }
    }

    private enum StagingFailure: Error {
        /// A span lies outside the backing, or its position overflows.
        case outsideBacking
        /// Guest memory could not be read.
        case unreadable

        var responseType: GPUResponseType { self == .outsideBacking ? .errInvalidParameter : .errUnspec }
    }

    /// The bytes of every span, one after the other, read from the guest piece by piece into a buffer made once.
    private static func stage(
        _ spans: Spans, from backing: BackingLayout, at offset: UInt64, memory: some GuestMemoryReader
    ) throws(StagingFailure) -> [UInt8] {
        var staged = [UInt8](repeating: 0, count: spans.count * spans.bytes)
        var position = 0
        for span in 0..<UInt64(spans.count) {
            let (skip, wide) = span.multipliedReportingOverflow(by: UInt64(spans.stride))
            let (start, overflow) = offset.addingReportingOverflow(skip)
            guard !wide, !overflow, let pieces = backing.pieces(offset: start, length: UInt64(spans.bytes)) else {
                throw .outsideBacking
            }
            for piece in pieces {
                guard let bytes = memory.copyBytes(atPhysicalAddress: piece.address, count: piece.count),
                    bytes.count == piece.count, position + piece.count <= staged.count
                else { throw .unreadable }
                staged.replaceSubrange(position..<position + piece.count, with: bytes)
                position += piece.count
            }
        }
        return staged
    }

    /// Drops every resource, as a device reset does.
    package mutating func removeAll() {
        resources.removeAll()
        totalBytes = 0
    }
}

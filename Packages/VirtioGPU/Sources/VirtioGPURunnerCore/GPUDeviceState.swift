/// The pixels of the scanout after a flush: the scanout's rectangle of its resource, rows packed `width × 4` bytes apart.
public struct ScanoutUpdate: Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let format: GPUPixelFormat
    public let pixels: [UInt8]
}

/// What the device does with one request: the answer to write back (`nil` on the cursor queue, whose requests get none), the
/// log entry, and the new picture when the request flushed the scanout.
public struct HandledCommand: Sendable {
    public let response: [UInt8]?
    public let logEntry: CommandLogEntry
    public let scanoutUpdate: ScanoutUpdate?
}

/// The state of the 2D device: its resources, its one scanout and the cursor. It decodes and carries out each request the
/// guest sends, completely, before the answer is returned, so a fenced request is done when its answer arrives.
public struct GPUDeviceState: Sendable {
    public private(set) var store: ResourceStore
    /// The resource shown on scanout 0 and the rectangle of it that is shown, or `nil` while the scanout is off.
    public private(set) var scanout: (resourceID: UInt32, rect: GPURect)?
    public private(set) var cursor: GPUCursor?
    private var sequence: UInt64 = 0

    public init(limits: GPULimits = GPULimits()) {
        store = ResourceStore(limits: limits)
    }

    /// Handles the bytes of one request, copied once out of guest memory by the caller.
    public mutating func handle(_ bytes: [UInt8], queue: GPUQueueKind, memory: some GuestMemoryReader) -> HandledCommand {
        sequence += 1
        let request = GPUDecoder.decode(bytes, limits: store.limits)
        var update: ScanoutUpdate?
        let response: GPUResponse?
        switch (queue, request.command) {
        case (_, .failure(let failure)):
            response = queue == .control ? .error(failure.responseType) : nil
        case (.control, .success(let command)):
            (response, update) = control(command, memory: memory)
        case (.cursor, .success(let command)):
            cursorRequest(command)
            response = nil
        }
        let entry = CommandLogEntry(
            sequence: sequence, queue: queue, commandType: request.header.type, resourceID: (try? request.command.get())?.resourceID ?? 0,
            responseType: response?.type, byteCount: bytes.count)
        return HandledCommand(response: response?.encoded(answering: request.header), logEntry: entry, scanoutUpdate: update)
    }

    /// Forgets every resource, the scanout and the cursor, as a device reset does. The sequence keeps counting.
    public mutating func reset() {
        store.removeAll()
        scanout = nil
        cursor = nil
    }

    private mutating func control(_ command: GPUCommand, memory: some GuestMemoryReader) -> (GPUResponse, ScanoutUpdate?) {
        switch command {
        case .getDisplayInfo:
            let rect = GPURect(x: 0, y: 0, width: store.limits.displayWidth, height: store.limits.displayHeight)
            return (.displayInfo([GPUDisplayMode(rect: rect, enabled: true)]), nil)
        case .resourceCreate2D(let id, let format, let width, let height):
            return (answer(store.create2D(resourceID: id, format: format, width: width, height: height)), nil)
        case .resourceUnref(let id):
            if scanout?.resourceID == id { scanout = nil }
            return (answer(store.unref(id)), nil)
        case .setScanout(let rect, let scanoutID, let id):
            return (answer(setScanout(rect: rect, scanoutID: scanoutID, resourceID: id)), nil)
        case .resourceFlush(let rect, let id):
            return flush(rect: rect, resourceID: id)
        case .transferToHost2D(let rect, let offset, let id):
            return (answer(store.transferToHost2D(resourceID: id, rect: rect, offset: offset, memory: memory)), nil)
        case .resourceAttachBacking(let id, let entries):
            return (answer(store.attachBacking(id, entries: entries)), nil)
        case .resourceDetachBacking(let id):
            return (answer(store.detachBacking(id)), nil)
        case .getEDID, .updateCursor, .moveCursor:
            // EDID is not offered, and cursor requests belong on the cursor queue.
            return (.error(.errUnspec), nil)
        }
    }

    private func answer(_ type: GPUResponseType) -> GPUResponse {
        type == .okNoData ? .noData : .error(type)
    }

    /// Resource 0 turns the scanout off; any other must exist and hold the rectangle shown.
    private mutating func setScanout(rect: GPURect, scanoutID: UInt32, resourceID id: UInt32) -> GPUResponseType {
        guard scanoutID == 0 else { return .errInvalidScanoutID }
        guard id != 0 else {
            scanout = nil
            return .okNoData
        }
        guard let resource = store.resource(id) else { return .errInvalidResourceID }
        guard rect.width > 0, rect.height > 0, rect.fits(width: resource.width, height: resource.height) else {
            return .errInvalidParameter
        }
        scanout = (id, rect)
        return .okNoData
    }

    /// A flush of the scanout's resource that touches the scanout's rectangle gives the new picture of the whole scanout.
    private func flush(rect: GPURect, resourceID id: UInt32) -> (GPUResponse, ScanoutUpdate?) {
        guard let resource = store.resource(id) else { return (.error(.errInvalidResourceID), nil) }
        guard rect.fits(width: resource.width, height: resource.height) else { return (.error(.errInvalidParameter), nil) }
        guard let scanout, scanout.resourceID == id, rect.intersects(scanout.rect) else { return (.noData, nil) }
        return (.noData, Self.picture(of: resource, in: scanout.rect))
    }

    /// The rectangle's rows of the resource; the rectangle was checked to fit when the scanout was set.
    private static func picture(of resource: GPUResource, in rect: GPURect) -> ScanoutUpdate {
        let rowBytes = Int(rect.width) * GPUPixelFormat.bytesPerPixel
        var pixels: [UInt8] = []
        pixels.reserveCapacity(rowBytes * Int(rect.height))
        for row in 0..<Int(rect.height) {
            let start = (Int(rect.y) + row) * resource.stride + Int(rect.x) * GPUPixelFormat.bytesPerPixel
            pixels.append(contentsOf: resource.pixels[start..<start + rowBytes])
        }
        return ScanoutUpdate(width: rect.width, height: rect.height, format: resource.format, pixels: pixels)
    }

    /// Cursor requests are recorded, not drawn: the scanout picture has no cursor.
    private mutating func cursorRequest(_ command: GPUCommand) {
        switch command {
        case .updateCursor(let new):
            cursor = new
        case .moveCursor(let moved):
            // A move keeps the image and hot spot of the last update.
            cursor = GPUCursor(
                scanoutID: moved.scanoutID, x: moved.x, y: moved.y, resourceID: cursor?.resourceID ?? 0, hotX: cursor?.hotX ?? 0,
                hotY: cursor?.hotY ?? 0)
        default:
            break
        }
    }
}

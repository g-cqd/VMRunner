/// The pixels of the scanout after a flush: the scanout's rectangle of its resource, rows packed `width × 4` bytes apart.
package struct ScanoutUpdate: Equatable, Sendable {
    package let width: UInt32
    package let height: UInt32
    package let format: GPUPixelFormat
    package let pixels: [UInt8]

    /// Also used by the bounded Windows RAM framebuffer adapter; the presenter validates byte count before making an image.
    package init(width: UInt32, height: UInt32, format: GPUPixelFormat, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
    }
}

/// What the device does with one request: the answer to write back (`nil` on the cursor queue, whose requests get none), the
/// log entry, the new picture when the request flushed the scanout, and what a cursor request changed.
package struct HandledCommand: Sendable {
    package let response: [UInt8]?
    package let logEntry: CommandLogEntry
    package let scanoutUpdate: ScanoutUpdate?
    package let cursorUpdate: CursorUpdate?
}

/// The state of the 2D device: its resources, its one scanout and the cursor. It decodes and carries out each request the
/// guest sends, completely, before the answer is returned, so a fenced request is done when its answer arrives.
package struct GPUDeviceState: Sendable {
    package private(set) var store: ResourceStore
    /// The resource shown on scanout 0 and the rectangle of it that is shown, or `nil` while the scanout is off.
    package private(set) var scanout: (resourceID: UInt32, rect: GPURect)?
    package private(set) var cursor: GPUCursor?
    /// The size of the one display, which the next display-information answer reports.
    package private(set) var displayWidth: UInt32
    package private(set) var displayHeight: UInt32
    private var sequence: UInt64 = 0

    package init(limits: GPULimits = GPULimits()) {
        store = ResourceStore(limits: limits)
        displayWidth = limits.displayWidth
        displayHeight = limits.displayHeight
    }

    /// Changes the size the display-information answers report, for a host whose window was resized. Refused (`false`, nothing
    /// changed) when `GPULimits.allowsDisplay` says no. The guest only asks again when the host tells it, by setting the display
    /// event in the configuration space (`GPUWire.eventDisplay`). A device reset keeps the size: it is the host's choice.
    package mutating func setDisplaySize(width: UInt32, height: UInt32) -> Bool {
        guard store.limits.allowsDisplay(width: width, height: height) else { return false }
        displayWidth = width
        displayHeight = height
        return true
    }

    /// Handles the bytes of one request, copied once out of guest memory by the caller.
    package mutating func handle(_ bytes: [UInt8], queue: GPUQueueKind, memory: some GuestMemoryReader) -> HandledCommand {
        sequence += 1
        let request = GPUDecoder.decode(bytes, limits: store.limits)
        var update: ScanoutUpdate?
        var cursorUpdate: CursorUpdate?
        let response: GPUResponse?
        switch (queue, request.command) {
        case (_, .failure(let failure)):
            response = queue == .control ? .error(failure.responseType) : nil
        case (.control, .success(let command)):
            (response, update) = control(command, memory: memory)
        case (.cursor, .success(let command)):
            cursorUpdate = cursorRequest(command)
            response = nil
        }
        let entry = CommandLogEntry(
            sequence: sequence, queue: queue, commandType: request.header.type, resourceID: (try? request.command.get())?.resourceID ?? 0,
            responseType: response?.type, byteCount: bytes.count)
        return HandledCommand(
            response: response?.encoded(answering: request.header), logEntry: entry, scanoutUpdate: update, cursorUpdate: cursorUpdate)
    }

    /// Forgets every resource, the scanout and the cursor, as a device reset does. The sequence keeps counting.
    package mutating func reset() {
        store.removeAll()
        scanout = nil
        cursor = nil
    }

    private mutating func control(_ command: GPUCommand, memory: some GuestMemoryReader) -> (GPUResponse, ScanoutUpdate?) {
        switch command {
        case .getDisplayInfo:
            let rect = GPURect(x: 0, y: 0, width: displayWidth, height: displayHeight)
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

    /// A cursor request is recorded in `cursor` and described to the host, which draws it: the scanout picture has no cursor.
    private mutating func cursorRequest(_ command: GPUCommand) -> CursorUpdate? {
        switch command {
        case .updateCursor(let new):
            cursor = new
            return CursorUpdate(x: new.x, y: new.y, hotX: new.hotX, hotY: new.hotY, image: cursorImage(resourceID: new.resourceID))
        case .moveCursor(let moved):
            // A move keeps the image and hot spot of the last update.
            let kept = GPUCursor(
                scanoutID: moved.scanoutID, x: moved.x, y: moved.y, resourceID: cursor?.resourceID ?? 0, hotX: cursor?.hotX ?? 0,
                hotY: cursor?.hotY ?? 0)
            cursor = kept
            return CursorUpdate(x: kept.x, y: kept.y, hotX: kept.hotX, hotY: kept.hotY, image: .unchanged)
        default:
            return nil
        }
    }

    /// The cursor's image: a picture of its resource as it is now, or none when the guest named no resource (resource 0 hides the
    /// cursor), one that does not exist, or one larger than `GPULimits.maxCursorSide`.
    private func cursorImage(resourceID id: UInt32) -> CursorUpdate.Image {
        let side = store.limits.maxCursorSide
        guard let resource = store.resource(id), resource.width <= side, resource.height <= side else { return .hidden }
        return .shown(Self.picture(of: resource, in: GPURect(x: 0, y: 0, width: resource.width, height: resource.height)))
    }
}

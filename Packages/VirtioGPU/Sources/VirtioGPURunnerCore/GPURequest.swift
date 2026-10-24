/// A decoded 2D request.
public enum GPUCommand: Equatable, Sendable {
    case getDisplayInfo
    case resourceCreate2D(resourceID: UInt32, format: UInt32, width: UInt32, height: UInt32)
    case resourceUnref(resourceID: UInt32)
    case setScanout(rect: GPURect, scanoutID: UInt32, resourceID: UInt32)
    case resourceFlush(rect: GPURect, resourceID: UInt32)
    case transferToHost2D(rect: GPURect, offset: UInt64, resourceID: UInt32)
    case resourceAttachBacking(resourceID: UInt32, entries: [GPUMemoryEntry])
    case resourceDetachBacking(resourceID: UInt32)
    case getEDID(scanoutID: UInt32)
    case updateCursor(GPUCursor)
    case moveCursor(GPUCursor)

    /// The resource the request names, for the command log; 0 when it names none.
    public var resourceID: UInt32 {
        switch self {
        case .getDisplayInfo, .getEDID: 0
        case .resourceCreate2D(let id, _, _, _), .resourceUnref(let id), .setScanout(_, _, let id), .resourceFlush(_, let id),
            .transferToHost2D(_, _, let id), .resourceAttachBacking(let id, _), .resourceDetachBacking(let id):
            id
        case .updateCursor(let cursor), .moveCursor(let cursor): cursor.resourceID
        }
    }
}

/// Why a request could not be decoded, and the answer it gets: a request too short for its type, or of a type the device does
/// not implement, is answered as unsupported (`errUnspec`); a request whose values break a limit as an invalid parameter.
public enum GPUDecodeFailure: Error, Equatable, Sendable {
    case shorterThanHeader(length: Int)
    case unsupported(type: UInt32)
    case shorterThanCommand(type: UInt32, needed: Int, length: Int)
    case longerThanLimit(length: Int)
    case tooManyEntries(count: UInt32)
    case entriesMissing(count: UInt32, length: Int)
    case invalidEntry(index: Int)

    public var responseType: GPUResponseType {
        switch self {
        case .shorterThanHeader, .unsupported, .shorterThanCommand: .errUnspec
        case .longerThanLimit, .tooManyEntries, .entriesMissing, .invalidEntry: .errInvalidParameter
        }
    }
}

/// A request as read from the guest: its header (zeroed when the request is too short to carry one) and its command or the
/// reason it has none.
public struct GPURequest: Equatable, Sendable {
    public let header: GPUControlHeader
    public let command: Result<GPUCommand, GPUDecodeFailure>
}

/// Decodes one request from the bytes the device copied out of guest memory. The copy is made once, before decoding, so the
/// guest cannot change a value between its check and its use; every length, count and offset is checked here or by the
/// resource store, and nothing is allocated for the guest before its size has been checked against `GPULimits`.
public enum GPUDecoder {
    public static func decode(_ bytes: [UInt8], limits: GPULimits) -> GPURequest {
        var reader = ByteReader(bytes)
        guard let header = readHeader(&reader) else {
            return GPURequest(header: .unreadable, command: .failure(.shorterThanHeader(length: bytes.count)))
        }
        guard bytes.count <= limits.maxCommandBytes else {
            return GPURequest(header: header, command: .failure(.longerThanLimit(length: bytes.count)))
        }
        guard let type = GPUCommandType(rawValue: header.type) else {
            return GPURequest(header: header, command: .failure(.unsupported(type: header.type)))
        }
        let needed = fixedSize(of: type)
        guard bytes.count >= needed else {
            let failure = GPUDecodeFailure.shorterThanCommand(type: header.type, needed: needed, length: bytes.count)
            return GPURequest(header: header, command: .failure(failure))
        }
        return GPURequest(header: header, command: body(of: type, from: &reader, limits: limits))
    }

    private static func readHeader(_ reader: inout ByteReader) -> GPUControlHeader? {
        guard let type = reader.u32(), let flags = reader.u32(), let fence = reader.u64(), let context = reader.u32(),
            let ring = reader.u8(), reader.skip(3)
        else { return nil }
        return GPUControlHeader(type: type, flags: flags, fenceID: fence, contextID: context, ringIndex: ring)
    }

    /// The size of the fixed part of a request of `type`, header included.
    static func fixedSize(of type: GPUCommandType) -> Int {
        switch type {
        case .getDisplayInfo: GPUWireSize.getDisplayInfo
        case .resourceCreate2D: GPUWireSize.resourceCreate2D
        case .resourceUnref: GPUWireSize.resourceUnref
        case .setScanout: GPUWireSize.setScanout
        case .resourceFlush: GPUWireSize.resourceFlush
        case .transferToHost2D: GPUWireSize.transferToHost2D
        case .resourceAttachBacking: GPUWireSize.attachBacking
        case .resourceDetachBacking: GPUWireSize.detachBacking
        case .getEDID: GPUWireSize.getEDID
        case .updateCursor, .moveCursor: GPUWireSize.cursor
        }
    }

    /// The command after the header. The caller checked that the fixed part is present, so the reads of the fixed part
    /// cannot fail; they still fall back to an answer rather than trap.
    private static func body(
        of type: GPUCommandType, from reader: inout ByteReader, limits: GPULimits
    ) -> Result<GPUCommand, GPUDecodeFailure> {
        let short = GPUDecodeFailure.shorterThanCommand(type: type.rawValue, needed: fixedSize(of: type), length: 0)
        let command: GPUCommand?
        switch type {
        case .getDisplayInfo: command = .getDisplayInfo
        case .resourceCreate2D: command = resourceCreate2D(&reader)
        case .resourceUnref: command = reader.u32().map { .resourceUnref(resourceID: $0) }
        case .setScanout: command = setScanout(&reader)
        case .resourceFlush: command = resourceFlush(&reader)
        case .transferToHost2D: command = transferToHost2D(&reader)
        case .resourceAttachBacking: return attachBacking(&reader, limits: limits)
        case .resourceDetachBacking: command = reader.u32().map { .resourceDetachBacking(resourceID: $0) }
        case .getEDID: command = reader.u32().map { .getEDID(scanoutID: $0) }
        case .updateCursor: command = cursor(&reader).map { .updateCursor($0) }
        case .moveCursor: command = cursor(&reader).map { .moveCursor($0) }
        }
        return command.map { .success($0) } ?? .failure(short)
    }

    private static func rect(_ reader: inout ByteReader) -> GPURect? {
        guard let x = reader.u32(), let y = reader.u32(), let width = reader.u32(), let height = reader.u32() else { return nil }
        return GPURect(x: x, y: y, width: width, height: height)
    }

    private static func resourceCreate2D(_ reader: inout ByteReader) -> GPUCommand? {
        guard let id = reader.u32(), let format = reader.u32(), let width = reader.u32(), let height = reader.u32() else { return nil }
        return .resourceCreate2D(resourceID: id, format: format, width: width, height: height)
    }

    private static func setScanout(_ reader: inout ByteReader) -> GPUCommand? {
        guard let rect = rect(&reader), let scanout = reader.u32(), let id = reader.u32() else { return nil }
        return .setScanout(rect: rect, scanoutID: scanout, resourceID: id)
    }

    private static func resourceFlush(_ reader: inout ByteReader) -> GPUCommand? {
        guard let rect = rect(&reader), let id = reader.u32() else { return nil }
        return .resourceFlush(rect: rect, resourceID: id)
    }

    private static func transferToHost2D(_ reader: inout ByteReader) -> GPUCommand? {
        guard let rect = rect(&reader), let offset = reader.u64(), let id = reader.u32() else { return nil }
        return .transferToHost2D(rect: rect, offset: offset, resourceID: id)
    }

    private static func cursor(_ reader: inout ByteReader) -> GPUCursor? {
        guard let scanout = reader.u32(), let x = reader.u32(), let y = reader.u32(), reader.skip(4), let id = reader.u32(),
            let hotX = reader.u32(), let hotY = reader.u32()
        else { return nil }
        return GPUCursor(scanoutID: scanout, x: x, y: y, resourceID: id, hotX: hotX, hotY: hotY)
    }

    /// The entry count is checked against the limit and against the bytes actually present before the entries array is
    /// made, so a guest cannot make the device allocate for entries it did not send.
    private static func attachBacking(_ reader: inout ByteReader, limits: GPULimits) -> Result<GPUCommand, GPUDecodeFailure> {
        guard let id = reader.u32(), let count = reader.u32() else {
            let type = GPUCommandType.resourceAttachBacking.rawValue
            return .failure(.shorterThanCommand(type: type, needed: GPUWireSize.attachBacking, length: 0))
        }
        guard count <= limits.maxBackingEntries else { return .failure(.tooManyEntries(count: count)) }
        let present = reader.remaining / GPUWireSize.memoryEntry
        guard Int(count) <= present else { return .failure(.entriesMissing(count: count, length: reader.remaining)) }
        var entries: [GPUMemoryEntry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            guard let address = reader.u64(), let length = reader.u32(), reader.skip(4) else {
                return .failure(.entriesMissing(count: count, length: reader.remaining))
            }
            guard length > 0, address.addingReportingOverflow(UInt64(length)).overflow == false else {
                return .failure(.invalidEntry(index: index))
            }
            entries.append(GPUMemoryEntry(address: address, length: length))
        }
        return .success(.resourceAttachBacking(resourceID: id, entries: entries))
    }
}

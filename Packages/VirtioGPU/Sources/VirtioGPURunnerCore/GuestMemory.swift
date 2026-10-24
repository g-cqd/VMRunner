/// Read access to the guest's RAM, as the device sees it. The guest may change its memory at any time, so an implementation
/// returns a copy, and the store uses only that copy.
public protocol GuestMemoryReader {
    /// A copy of `count` bytes of guest RAM starting at the guest physical `address`, or `nil` when that range is not guest
    /// RAM.
    func copyBytes(atPhysicalAddress address: UInt64, count: Int) -> [UInt8]?
}

/// A piece of guest RAM: where it starts and how many bytes it has.
public struct GuestRange: Equatable, Sendable {
    public var address: UInt64
    public var count: Int

    public init(address: UInt64, count: Int) {
        self.address = address
        self.count = count
    }
}

/// The guest memory a resource's pixels live in: its entries, end to end, as one run of bytes.
public struct BackingLayout: Equatable, Sendable {
    public let entries: [GPUMemoryEntry]
    /// Where each entry starts in the run.
    private let starts: [UInt64]
    /// The length of the run.
    public let totalLength: UInt64

    /// `nil` for an entry of zero length or one that wraps past the top of the address space (the decoder already refuses
    /// both), or a total that overflows.
    public init?(entries: [GPUMemoryEntry]) {
        var starts: [UInt64] = []
        starts.reserveCapacity(entries.count)
        var total: UInt64 = 0
        for entry in entries {
            guard entry.length > 0, !entry.address.addingReportingOverflow(UInt64(entry.length)).overflow else { return nil }
            starts.append(total)
            let (sum, overflow) = total.addingReportingOverflow(UInt64(entry.length))
            guard !overflow else { return nil }
            total = sum
        }
        self.entries = entries
        self.starts = starts
        self.totalLength = total
    }

    /// The pieces of guest memory that hold bytes `offset ..< offset + length` of the run, in order; `nil` when the range
    /// ends past the run or its end overflows. A zero length gives no pieces.
    public func pieces(offset: UInt64, length: UInt64) -> [GuestRange]? {
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow, end <= totalLength else { return nil }
        guard length > 0 else { return [] }
        var pieces: [GuestRange] = []
        var index = entryIndex(containing: offset)
        var position = offset
        while position < end, index < entries.count {
            let skip = position - starts[index]
            let available = UInt64(entries[index].length) - skip
            let take = min(available, end - position)
            pieces.append(GuestRange(address: entries[index].address + skip, count: Int(take)))
            position += take
            index += 1
        }
        return pieces
    }

    /// The last entry that starts at or before `offset` (a binary search: a guest controls the number of entries).
    private func entryIndex(containing offset: UInt64) -> Int {
        var low = 0
        var high = starts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle } else { high = middle }
        }
        return low
    }
}

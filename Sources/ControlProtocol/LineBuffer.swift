/// Cuts a byte stream into lines that end with a newline, holding at most `limit` bytes of a line that has not ended plus
/// what one read added. Call `next()` after every `append`: a client cannot make it grow further.
public struct LineBuffer: Equatable, Sendable {
    public enum Next: Equatable, Sendable {
        /// A whole line, its newline removed.
        case line([UInt8])
        case needMore
        /// The line is longer than the limit, ended or not.
        case tooLong
    }

    public let limit: Int
    private var pending: [UInt8] = []

    public init(limit: Int) { self.limit = limit }

    /// Bytes waiting for their newline.
    public var pendingCount: Int { pending.count }

    public mutating func append(_ bytes: some Sequence<UInt8>) { pending.append(contentsOf: bytes) }

    public mutating func next() -> Next {
        if let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            guard end <= limit else { return .tooLong }
            let line = Array(pending[..<end])
            pending.removeSubrange(...end)
            return .line(line)
        }
        return pending.count > limit ? .tooLong : .needMore
    }
}

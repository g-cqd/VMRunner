import Darwin
import Foundation
import Synchronization
import os

/// Which file an open descriptor is: two descriptors of the same file have the same identity.
private struct FileIdentity: Equatable {
    let device: Int64
    let inode: UInt64
}

/// An output file that passed the checks, open.
private struct OpenedOutput {
    let descriptor: Int32
    let size: Int
    let identity: FileIdentity
}

/// What the checks on an output file found.
private enum OutputFileInspection {
    case accepted(size: Int, identity: FileIdentity)
    case refused(String)

    /// Looks at the open descriptor: a regular file, owned by this user, with no other name and closed to other users.
    /// Whatever sits at the path, a planted link or a file someone else owns included, is never written or read.
    init(_ descriptor: Int32) {
        var status = stat()
        // `status` is a local that outlives the call, which fills it.
        guard unsafe fstat(descriptor, &status) == 0 else {
            self = .refused("it could not be inspected")
            return
        }
        if status.st_mode & S_IFMT != S_IFREG {
            self = .refused("it is not a regular file")
        } else if status.st_uid != geteuid() {
            self = .refused("it belongs to another user")
        } else if status.st_nlink != 1 {
            self = .refused("it has more than one name")
        } else if status.st_mode & 0o077 != 0 {
            self = .refused("it is open to other users")
        } else {
            self = .accepted(size: Int(status.st_size), identity: FileIdentity(device: Int64(status.st_dev), inode: status.st_ino))
        }
    }
}

/// What opening an output file came to. `failed` holds a sentence without the path, the same for every file it happens to.
private enum OutputOpening {
    case opened(OpenedOutput)
    case missing
    case failed(String)
}

/// Opens an output file for reading or appending, with the checks above. Never waits: a pipe planted at the path would hold
/// an ordinary open until another process opened its other end, before the checks could refuse it.
private func openOutputFile(_ url: URL, flags: Int32) -> OutputOpening {
    // `open` gets a NUL-terminated copy of the path that outlives the call; O_NOFOLLOW makes it fail with ELOOP on a link.
    let descriptor = unsafe open(url.path, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        let code = errno
        switch code {
        case ENOENT: return .missing
        case ELOOP: return .failed("it is a link")
        default: return .failed("it could not be opened (error \(code))")
        }
    }
    switch OutputFileInspection(descriptor) {
    case .accepted(let size, let identity):
        return .opened(OpenedOutput(descriptor: descriptor, size: size, identity: identity))
    case .refused(let reason):
        _ = Darwin.close(descriptor)
        return .failed(reason)
    }
}

/// Where a container machine's output is kept: a file in the machine's folder that every run appends to, and a second one
/// that holds what the first held before it grew past its limit. Together they are the most recent output, at most twice the
/// limit.
///
/// Appending never waits for the disk. The bytes go into a bounded buffer and a drain writes them on a queue shared by all
/// files, so two runs of one machine never write at the same time; a drain opens the file, writes, and closes it, so no
/// descriptor stays open between drains. When the disk is slower than the container the buffer fills, new bytes are dropped
/// and counted, and the next drain says how many.
///
/// The files are private (mode 0600) and are never followed through a link: a file that is not a regular file of this user,
/// that has another name, or that is open to others is left alone and what would have been written to it is dropped. Each
/// kind of refusal or failure is logged once per file object, without the path.
final class ContainerOutputFile: Sendable {
    static let defaultLimit = 1 << 20

    /// The queue the drains of every file run on, one at a time.
    private static let drains = DispatchQueue(label: "container-output-file", qos: .utility)  // swiftlint:disable:this no_dispatch_queue

    private struct State {
        var bytes: [UInt8] = []
        var dropped = 0
        var scheduled = false
        /// The kinds of failure already logged.
        var reported: Set<String> = []
    }

    private let current: URL
    private let previous: URL
    private let limit: Int
    private let pendingLimit: Int
    private let queue: DispatchQueue  // swiftlint:disable:this no_dispatch_queue
    private let state = Mutex(State())

    /// `queue` runs the drains one at a time; by default the queue every file shares. A test passes a queue it holds back to
    /// decide when the drains run.
    init(
        current: URL, previous: URL, limit: Int = defaultLimit, pendingLimit: Int = defaultLimit,
        queue: DispatchQueue? = nil  // swiftlint:disable:this no_dispatch_queue
    ) {
        self.current = current
        self.previous = previous
        self.limit = limit
        self.pendingLimit = pendingLimit
        self.queue = queue ?? Self.drains
    }

    convenience init(bundle: VMBundle) {
        self.init(current: bundle.containerOutput, previous: bundle.previousContainerOutput)
    }

    /// Queues `bytes` to be written. Returns at once. Once `pendingLimit` bytes wait, whatever is appended is dropped whole
    /// and counted.
    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let mustSchedule = state.withLock { state -> Bool in
            if state.bytes.count < pendingLimit { state.bytes += bytes } else { state.dropped += bytes.count }
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        if mustSchedule { queue.async { self.drain() } }
    }

    /// Returns when every drain that was queued before the call has finished.
    func drained() async {  // @dw:accept:this referenced-only-by-tests -- tests wait for the queued writes
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: Writing

    private func drain() {
        while let batch = takeBatch() { store(batch) }
    }

    /// The note that says how much was dropped.
    private static func droppedNote(_ count: Int) -> [UInt8] {
        Array("[dropped \(count) bytes: the disk was slower than the container]\n".utf8)
    }

    /// The most room the note can take.
    private static let noteReserve = droppedNote(Int.max).count

    /// Everything waiting; nil, with the drain marked as done, when nothing waits. When bytes were dropped it is led by the
    /// note, and the waiting bytes are cut at their start, at a character boundary, to leave the note room within the limit:
    /// the note must not be what the limit cuts off. What that cut removes is counted as dropped too.
    private func takeBatch() -> [UInt8]? {
        state.withLock { state -> [UInt8]? in
            guard !state.bytes.isEmpty || state.dropped > 0 else {
                state.scheduled = false
                return nil
            }
            var batch = state.bytes
            if state.dropped > 0 {
                let room = max(limit - Self.noteReserve, 0)
                var start = max(batch.count - room, 0)
                while start < batch.count, batch[start] & 0xC0 == 0x80 { start += 1 }
                state.dropped += start
                batch = Self.droppedNote(state.dropped) + batch[start...]
            }
            state.bytes = []
            state.dropped = 0
            return batch
        }
    }

    /// Writes `batch` at the end of the current file, which becomes the previous one first when it would grow past the limit.
    private func store(_ batch: [UInt8]) {
        let bytes = Self.lastBytes(of: batch, limit: limit)
        guard var file = openForAppending() else { return }
        if file.size + bytes.count > limit {
            _ = Darwin.close(file.descriptor)
            // The rename replaces the older previous file in one step, and a link planted there goes without being followed.
            guard unsafe rename(current.path, previous.path) == 0 else {
                report("it could not be rotated (error \(errno))")
                return
            }
            guard let fresh = create() else { return }
            file = fresh
        }
        defer { _ = Darwin.close(file.descriptor) }
        if let failure = Self.writeAll(file.descriptor, bytes) { report(failure) }
    }

    /// Logs a kind of failure, the first time this file meets it.
    private func report(_ kind: String) {
        guard state.withLock({ $0.reported.insert(kind).inserted }) else { return }
        Log.container.error("The container output file: \(kind, privacy: .public)")
    }

    /// The last `limit` bytes of `bytes`, cut forward to the start of a character.
    private static func lastBytes(of bytes: [UInt8], limit: Int) -> ArraySlice<UInt8> {
        guard bytes.count > limit else { return bytes[...] }
        var start = bytes.count - limit
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return bytes[start...]
    }

    /// The current file open for appending, made when it is missing. A refused or unopenable file is logged and left as it is.
    private func openForAppending() -> OpenedOutput? {
        switch openOutputFile(current, flags: O_WRONLY | O_APPEND) {
        case .opened(let file):
            return file
        case .missing:
            return create()
        case .failed(let kind):
            report("was refused: \(kind)")
            return nil
        }
    }

    /// Makes the current file, private, and never over a name that exists.
    private func create() -> OpenedOutput? {
        // `open` gets a NUL-terminated copy of the path that outlives the call; O_EXCL makes it fail when the name exists (a
        // link or a pipe included) and O_NOFOLLOW when the last component is a link.
        let descriptor = unsafe open(current.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            report("could not be created (error \(code))")
            return nil
        }
        // The umask may have taken permissions away from the 0600 asked for, never given any; this settles it.
        _ = fchmod(descriptor, 0o600)
        guard case .accepted(_, let identity) = OutputFileInspection(descriptor) else {
            _ = Darwin.close(descriptor)
            report("could not be inspected after it was created")
            return nil
        }
        return OpenedOutput(descriptor: descriptor, size: 0, identity: identity)
    }

    /// Writes all of `bytes`; the sentence for what went wrong, or nil.
    private static func writeAll(_ descriptor: Int32, _ bytes: ArraySlice<UInt8>) -> String? {
        bytes.withUnsafeBytes { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let count = unsafe write(descriptor, base + offset, buffer.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                let code = errno
                if count < 0, code == EINTR { continue }
                return count < 0 ? "could not be written (error \(code))" : "took no more bytes"
            }
            return nil
        }
    }

    // MARK: Reading

    /// The file open for reading when it passes the checks, nil otherwise (missing included). Reading says nothing in the log:
    /// whoever asks for the tail gets an empty one.
    private static func openForReading(_ url: URL) -> OpenedOutput? {
        guard case .opened(let file) = openOutputFile(url, flags: O_RDONLY) else { return nil }
        return file
    }

    /// The last `limit` bytes of the previous file followed by the current one, as text cut forward to the start of a
    /// character, and whether there was more. A missing file reads as empty, and so does one that fails the checks of the
    /// writer. Reads no more than `limit` bytes, whatever the files hold. The current file is opened first: a rotation in
    /// between would show the same file as the previous one too, and then it is read once.
    static func tail(current: URL, previous: URL, limit: Int) -> (text: String, truncated: Bool) {
        let newest = openForReading(current)
        let older = openForReading(previous)
        defer {
            for file in [newest, older].compactMap({ $0 }) { _ = Darwin.close(file.descriptor) }
        }
        let files = [older.flatMap { $0.identity == newest?.identity ? nil : $0 }, newest].compactMap { $0 }
        let total = files.reduce(0) { $0 + $1.size }
        guard limit > 0, total > 0 else { return ("", total > 0) }
        var skip = total - min(limit, total)
        var bytes: [UInt8] = []
        for file in files {
            guard skip < file.size else {
                skip -= file.size
                continue
            }
            bytes += readBytes(file.descriptor, from: skip, count: file.size - skip)
            skip = 0
        }
        let truncated = total > limit
        var start = 0
        if truncated { while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 } }
        return (String(decoding: bytes[start...], as: UTF8.self), truncated)  // swiftlint:disable:this optional_data_string_conversion
    }

    /// Up to `count` bytes of the file from `offset`; fewer when the file is shorter than it was.
    private static func readBytes(_ descriptor: Int32, from offset: Int, count: Int) -> [UInt8] {
        unsafe [UInt8](unsafeUninitializedCapacity: count) { buffer, filled in
            filled = 0
            guard let base = buffer.baseAddress else { return }
            while filled < count {
                let got = unsafe pread(descriptor, base + filled, count - filled, off_t(offset + filled))
                if got > 0 {
                    filled += got
                } else if got < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

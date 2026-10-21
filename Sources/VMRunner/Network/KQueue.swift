import Foundation

/// A readiness event, in the shell's own terms.
struct ReadinessEvent {
    enum Kind {
        case readable, writable, wakeup
    }

    var kind: Kind
    var descriptor: Int32
    var token: UInt64
    /// The peer closed (read) or the socket failed.
    var isEnd: Bool
}

/// One filter change for a descriptor.
struct ReadinessChange {
    var descriptor: Int32
    var token: UInt64
    var isRead: Bool
    var enabled: Bool
}

/// The cross-thread half of a kernel queue: only `trigger()` is used off the loop thread, and it only needs the
/// immutable descriptor.
@safe
final class KQueueHandle: Sendable {
    let descriptor: Int32

    private static let wakeIdentifier: UInt = 1

    init?() {
        let created = kqueue()
        guard created >= 0 else { return nil }
        descriptor = created
        var registration = unsafe kevent(
            ident: Self.wakeIdentifier, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        // One change, no event list: registers the user event.
        if unsafe kevent(created, &registration, 1, nil, 0, nil) < 0 {
            close(created)
            return nil
        }
    }

    deinit {
        close(descriptor)
    }

    /// Wakes a thread blocked in ``KQueuePoller/wait(changes:events:timeout:)``. Safe from any thread.
    func trigger() {
        var change = unsafe kevent(
            ident: Self.wakeIdentifier, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
        // One change, no event list.
        _ = unsafe kevent(descriptor, &change, 1, nil, 0, nil)
    }

    @unsafe
    fileprivate static func decode(_ event: kevent) -> ReadinessEvent {
        let filter = unsafe event.filter
        let identifier = unsafe event.ident
        let flags = unsafe event.flags
        if filter == Int16(EVFILT_USER), identifier == wakeIdentifier {
            return ReadinessEvent(kind: .wakeup, descriptor: -1, token: 0, isEnd: false)
        }
        return ReadinessEvent(
            kind: filter == Int16(EVFILT_READ) ? .readable : .writable, descriptor: Int32(truncatingIfNeeded: identifier),
            token: UInt64(UInt(bitPattern: unsafe event.udata)), isEnd: flags & UInt16(EV_EOF) != 0 || flags & UInt16(EV_ERROR) != 0)
    }

    @unsafe
    fileprivate static func encode(_ change: ReadinessChange) -> kevent {
        let filter = Int16(change.isRead ? EVFILT_READ : EVFILT_WRITE)
        let flags = UInt16(EV_ADD) | UInt16(change.enabled ? EV_ENABLE : EV_DISABLE)
        // The token travels as the opaque user pointer and comes back unchanged.
        return unsafe kevent(
            ident: UInt(change.descriptor), filter: filter, flags: flags, fflags: 0, data: 0,
            udata: UnsafeMutableRawPointer(bitPattern: UInt(change.token)))
    }
}

/// The loop thread's half: applies filter changes and waits. Preallocated buffers, no per-wait allocation.
@safe
final class KQueuePoller {
    private let handle: KQueueHandle
    @unsafe private var raw: [kevent]
    @unsafe private var changeList: [kevent]
    private let capacity: Int

    init(handle: KQueueHandle, capacity: Int = 256) {
        self.handle = handle
        self.capacity = capacity
        unsafe raw = Array(repeating: kevent(), count: capacity)
        unsafe changeList = []
        unsafe changeList.reserveCapacity(capacity)
    }

    /// Applies `changes` and waits up to `timeout` seconds (`nil` = forever) for events, filling `events`.
    func wait(changes: inout [ReadinessChange], events: inout [ReadinessEvent], timeout: TimeInterval?) {
        events.removeAll(keepingCapacity: true)
        unsafe changeList.removeAll(keepingCapacity: true)
        // Index loops, not `for ... in`: an unoptimized build allocates a generic iterator for each `for` loop, and this
        // runs on every wake of the loop thread.
        let applied = min(changes.count, capacity)
        var index = 0
        while index < applied {
            unsafe changeList.append(unsafe KQueueHandle.encode(changes[index]))
            index += 1
        }
        if applied > 0 { changes.removeFirst(applied) }
        var limit = timespec()
        if let timeout {
            limit.tv_sec = Int(timeout)
            limit.tv_nsec = Int((timeout - TimeInterval(Int(timeout))) * 1_000_000_000)
        }
        let queue = handle.descriptor
        let pending = Int32(unsafe changeList.count)
        let slots = Int32(capacity)
        let forever = timeout == nil
        // `changeList` and `raw` are separate arrays of `capacity` kevents that outlive the call.
        let count = unsafe changeList.withUnsafeBufferPointer { changeBuffer in
            unsafe raw.withUnsafeMutableBufferPointer { eventBuffer in
                withUnsafePointer(to: &limit) { timeoutPointer in
                    unsafe kevent(
                        queue, changeBuffer.baseAddress, pending, eventBuffer.baseAddress, slots, forever ? nil : timeoutPointer)
                }
            }
        }
        var ready = 0
        while ready < Int(count) {
            events.append(unsafe KQueueHandle.decode(unsafe raw[ready]))
            ready += 1
        }
    }
}

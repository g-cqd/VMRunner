import Foundation

/// A kernel event queue holding the descriptors one thread waits on. Only ``wake()`` may be called from another thread; it
/// needs nothing but the immutable queue descriptor.
@safe
final class ReadinessQueue: Sendable {
    /// One thing that happened: a descriptor became readable or writable, or the queue was woken.
    struct Event {
        enum Kind { case readable, writable, wakeup }
        var kind: Kind
        var descriptor: Int32
    }

    private static let wakeIdentifier: UInt = 1
    private static let capacity = 16

    private let queue: Int32

    init?() {
        let created = kqueue()
        guard created >= 0 else { return nil }
        queue = created
        // The wake-up event is edge-triggered: it fires once per trigger and clears itself when delivered.
        guard Self.apply(to: created, ident: Self.wakeIdentifier, filter: EVFILT_USER, flags: EV_ADD | EV_CLEAR) else {
            Darwin.close(created)
            return nil
        }
    }

    deinit {
        Darwin.close(queue)
    }

    /// Wakes a thread blocked in ``wait()``. Safe from any thread.
    func wake() {
        _ = Self.apply(to: queue, ident: Self.wakeIdentifier, filter: EVFILT_USER, flags: 0, fflags: UInt32(NOTE_TRIGGER))
    }

    /// Starts (`add`) or stops watching `descriptor` for readability or writability. Closing a descriptor removes its
    /// filters by itself, so only a descriptor that stays open needs `add: false`.
    func watch(_ descriptor: Int32, writing: Bool, add: Bool) {
        _ = Self.apply(
            to: queue, ident: UInt(descriptor), filter: writing ? EVFILT_WRITE : EVFILT_READ, flags: add ? EV_ADD | EV_ENABLE : EV_DELETE)
    }

    /// Submits one change to `queue` and returns whether the kernel took it.
    private static func apply(to queue: Int32, ident: UInt, filter: Int32, flags: Int32, fflags: UInt32 = 0) -> Bool {
        var change = unsafe kevent(
            ident: ident, filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
        // One change in, no event list out.
        return unsafe kevent(queue, &change, 1, nil, 0, nil) >= 0
    }

    /// Blocks until something happens and returns what.
    func wait() -> [Event] {
        var raw = unsafe Array(repeating: kevent(), count: Self.capacity)
        let count = raw.withUnsafeMutableBufferPointer { buffer in
            unsafe kevent(queue, nil, 0, buffer.baseAddress, Int32(Self.capacity), nil)
        }
        var events: [Event] = []
        var index = 0
        while index < Int(max(count, 0)) {
            let item = unsafe raw[index]
            index += 1
            let filter = unsafe item.filter
            let descriptor = Int32(truncatingIfNeeded: unsafe item.ident)
            if filter == Int16(EVFILT_USER) {
                events.append(Event(kind: .wakeup, descriptor: -1))
            } else if filter == Int16(EVFILT_READ) {
                events.append(Event(kind: .readable, descriptor: descriptor))
            } else if filter == Int16(EVFILT_WRITE) {
                events.append(Event(kind: .writable, descriptor: descriptor))
            }
        }
        return events
    }
}

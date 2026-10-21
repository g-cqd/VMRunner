import Synchronization

/// Commands for the loop thread, posted from anywhere: a mutex-guarded array plus a kernel-queue wakeup.
///
/// The loop checks ``hasPending`` between guest frames (one atomic load), so a command posted before a frame was sent
/// is always applied before that frame is read: `updatePolicy` followed by a connection attempt cannot be overtaken.
final class UserNetInbox: Sendable {
    private let commands = Mutex<[UserNetCommand]>([])
    private let pendingCount = Atomic<Int>(0)
    private let handle: KQueueHandle

    init(handle: KQueueHandle) {
        self.handle = handle
    }

    /// Whether a command is waiting. Cheap enough to call per frame.
    var hasPending: Bool { pendingCount.load(ordering: .acquiring) > 0 }

    func post(_ command: UserNetCommand) {
        commands.withLock { pending in
            pending.append(command)
            pendingCount.add(1, ordering: .releasing)
        }
        handle.trigger()
    }

    /// Moves every pending command into `buffer` (which is emptied first), in posting order.
    func drain(into buffer: inout [UserNetCommand]) {
        buffer.removeAll(keepingCapacity: true)
        commands.withLock { pending in
            swap(&pending, &buffer)
            pendingCount.store(0, ordering: .releasing)
        }
    }
}

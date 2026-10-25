import Foundation
import VirtioGPU
import Virtualization
import os

/// The host side of a virtio GPU for a Linux machine (roadmap 0014, ADR-0058), on the framework's custom virtio devices,
/// which need macOS 27. The framework calls it on the device queue, which is the main queue, so its state is main-actor state.
/// The library decides everything about a request (`GPUDeviceState.serve`); this class gives it the framework's queue elements
/// and guest memory, passes the pictures and cursor changes on to its sinks, and tells the guest when the display changed.
///
/// The configuration is made off the main actor, with the rest of the machine's configuration, so the conformance to the
/// configuration delegate is `@preconcurrency`: the framework still calls the object only on the main queue, and the compiler
/// checks that at run time instead of refusing to hand the object over.
@available(macOS 27.0, *)
@MainActor
final class CustomGPUDevice: NSObject, @preconcurrency VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    /// Where the guest's picture goes: each new picture of the scanout and each change of the guest's cursor. Both run on the
    /// main actor, inside the device's handling of a request, so they must not block.
    struct Sinks {
        var showFrame: @MainActor (ScanoutUpdate) -> Void
        var showCursor: @MainActor (CursorUpdate) -> Void
    }

    /// What can go wrong with a request, each logged once so that a guest cannot make the log grow.
    private enum Trouble {
        case oversized
        case unreadable
        case unanswered
        case writeFailed
        case updateFailed
    }

    /// How many elements one turn serves before the main queue is given back to the app. Each element is bounded by the
    /// library's limits, so a turn is too, and a guest that keeps the ring full cannot keep the main queue.
    static let turnBudget = 32

    private let sinks: Sinks
    private var state: GPUDeviceState
    private var device: VZCustomVirtioDevice?
    private var logged: Set<Trouble> = []
    /// The queues with a later turn already scheduled, so a busy guest does not pile up tasks.
    private var resuming: Set<UInt16> = []

    init(limits: GPULimits = GPULimits(), sinks: Sinks) {
        state = GPUDeviceState(limits: limits)
        self.sinks = sinks
    }

    /// Resizes the display the guest sees: the next display-information answer reports `width` × `height`, and the guest is told
    /// to ask for it by writing the configuration space (`GPUConfigSpace.displayChange`) once the framework has made the device.
    /// Returns `false` and changes nothing for a size the library refuses (`GPULimits.allowsDisplay`); `true` means the size is
    /// taken and the guest is being told, not that it has asked. The framework's update is asynchronous; a failure of it is
    /// logged once.
    func requestDisplaySize(width: UInt32, height: UInt32) -> Bool {
        guard state.setDisplaySize(width: width, height: height) else { return false }
        announceDisplayChange()
        return true
    }

    private func announceDisplayChange() {
        guard let device else { return }
        Task { [weak self] in
            for space in GPUConfigSpace.displayChange {
                do {
                    try await device.update(VZVirtioDeviceSpecificConfiguration(configurationData: Data(space.bytes)))
                } catch {
                    self?.report(.updateFailed, "Couldn't tell the guest the display changed (\(error.logKind))")
                    return
                }
            }
        }
    }

    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
        self.device = device
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        serveTurn(of: queue, on: device)
    }

    /// Serves up to `turnBudget` elements. A guest that notifies once for a batch does not notify again for the rest of it, so
    /// when the budget ended the turn another one is scheduled on the main actor, after whatever else is waiting there. The
    /// framework gives no way to look at the queue without taking an element, so that turn may find it empty.
    private func serveTurn(of queue: VZVirtioQueue, on device: VZCustomVirtioDevice) {
        let kind: GPUQueueKind = queue.queueIndex == GPUWire.cursorQueue ? .cursor : .control
        let more = state.serveTurn(
            from: GuestQueue(queue: queue), on: kind, memory: GuestMemoryMapping(device: device), budget: Self.turnBudget,
            whenHandled: { self.deliver($0) }, whenServed: { self.note($0) })
        guard more, resuming.insert(queue.queueIndex).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            resuming.remove(queue.queueIndex)
            serveTurn(of: queue, on: device)
        }
    }

    /// A reset forgets the guest's resources, scanout and cursor; the size the host chose for the display stays.
    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        state.reset()
    }

    private func deliver(_ handled: HandledCommand) {
        if let frame = handled.scanoutUpdate { sinks.showFrame(frame) }
        if let cursor = handled.cursorUpdate { sinks.showCursor(cursor) }
    }

    private func note(_ outcome: ServeOutcome) {
        switch outcome {
        case .handled(let answer):
            note(answer)
        case .oversized(let length, let answer):
            report(.oversized, "A request of \(length) bytes was refused: it is more than the GPU device reads")
            note(answer)
        case .unreadable(let length, let error):
            report(.unreadable, "Couldn't read a request of \(length) bytes (\(error.logKind))")
        }
    }

    private func note(_ answer: AnswerStatus) {
        switch answer {
        case .written, .notNeeded:
            break
        case .didNotFit(let needed, let available):
            report(.unanswered, "An answer of \(needed) bytes didn't fit the \(available) the guest left; nothing was written")
        case .failed(let error):
            report(.writeFailed, "Couldn't write an answer (\(error.logKind))")
        }
    }

    private func report(_ trouble: Trouble, _ message: String) {
        guard logged.insert(trouble).inserted else { return }
        Log.display.notice("\(message, privacy: .public)")
    }
}

import Foundation
import VirtioGPU
import Virtualization
import os

/// The host side of a virtio GPU for a Linux machine (roadmap 0014, ADR-0058), on the framework's custom virtio devices,
/// which need macOS 27. The framework calls it on the device queue, which is the main queue, so its state is main-actor state.
/// The library decides everything about a request (`GPUDeviceState.serve`); this class gives it the framework's queue elements
/// and guest memory, passes the pictures and cursor changes on to its sinks, and tells the guest when the display changed.
@available(macOS 27.0, *)
@MainActor
final class CustomGPUDevice: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
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
    }

    private let sinks: Sinks
    private var state: GPUDeviceState
    private var device: VZCustomVirtioDevice?
    private var logged: Set<Trouble> = []

    init(limits: GPULimits = GPULimits(), sinks: Sinks) {
        state = GPUDeviceState(limits: limits)
        self.sinks = sinks
    }

    /// Resizes the display the guest sees: the next display-information answer reports `width` × `height`, and the guest is told
    /// to ask for it by setting the display event in the configuration space. Returns `false` and changes nothing for a size
    /// the library refuses (`GPULimits.allowsDisplay`).
    func requestDisplaySize(width: UInt32, height: UInt32) async throws -> Bool {
        guard state.setDisplaySize(width: width, height: height) else { return false }
        if let device {
            let space = GPUConfigSpace(eventsRead: GPUWire.eventDisplay, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
            try await device.update(VZVirtioDeviceSpecificConfiguration(configurationData: Data(space.bytes)))
        }
        return true
    }

    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
        self.device = device
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        let kind: GPUQueueKind = queue.queueIndex == GPUWire.cursorQueue ? .cursor : .control
        let memory = GuestMemoryMapping(device: device)
        // Every element is taken before the method returns: a guest that notifies once does not notify again for them.
        while let element = queue.nextElement() {
            let outcome = state.serve(GuestQueueElement(element: element), on: kind, memory: memory) { handled in
                self.deliver(handled)
            }
            note(outcome)
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

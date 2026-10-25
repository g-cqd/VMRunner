import Foundation
import VirtioInput
import Virtualization

/// The host side of a virtio input device for a Linux machine, on the framework's custom virtio devices (macOS 27): a keyboard
/// or an absolute pointer, each a device of its own with the fixed configuration space of the library
/// (`VirtioInputStaticConfig`). The framework calls it on the main queue, so its state is main-actor state. The rules of the two
/// queues are `VirtioInputEndpoint`'s; this class gives it the framework's queues, tells it about the device's life, and makes
/// the configuration. The configuration conformance is `@preconcurrency` for the reason `CustomGPUDevice`'s is.
@available(macOS 27.0, *)
@MainActor
final class VirtioInputDevice: NSObject, @preconcurrency VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate,
    InputEventSink
{
    /// What can go wrong, each logged once so that a guest cannot make the log grow.
    private enum Trouble {
        case dropped
        case malformed
    }

    private let layout: VirtioInputStaticConfig
    private let label: String
    private let endpoint = VirtioInputEndpoint<GuestQueue>()
    /// The queues with a later turn already scheduled, so a busy guest does not pile up tasks.
    private var resuming: Set<UInt16> = []
    private var troubles = TroubleLog<Trouble>(Log.input)
    /// While the machine is paused the guest runs nothing, and events are not delivered.
    private var isPaused = false

    /// `label` names the device in the log.
    init(layout: VirtioInputStaticConfig, label: String) {
        self.layout = layout
        self.label = label
    }

    /// The device as the machine's configuration takes it (`customVirtioDevices`): device ID 18, PCI class 0x09 subclass 0x80,
    /// an event and a status queue, only `VIRTIO_F_VERSION_1`, the 136 bytes of the layout, and no save and restore.
    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        VZCustomVirtioDeviceConfiguration(
            deviceID: InputWire.deviceID, pciClass: (InputWire.pciClassID, InputWire.pciSubclassID), queueCount: InputWire.queueCount,
            versionOneSubset: InputWire.versionOneFeatureSubset1, space: layout.bytes, delegate: self)
    }

    /// Frames of events for the guest (`VirtioInputEndpoint.send`); none while the machine is paused.
    func send(_ frames: [InputEvent]) {
        guard !isPaused else { return }
        endpoint.send(frames)
        if endpoint.droppedFrameCount > 0 {
            troubles.notice(.dropped, "The guest's \(label) isn't reading events fast enough: input was dropped")
        }
    }

    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        device.delegate = self
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        serveTurn(of: queue)
    }

    /// Serves up to `CustomGPUDevice.turnBudget` elements of a queue. A guest that notifies once for a batch does not notify
    /// again for the rest of it, so when the budget ended the turn another one is scheduled on the main actor.
    private func serveTurn(of queue: VZVirtioQueue) {
        let elements = GuestQueue(queue: queue)
        let more: Bool
        switch queue.queueIndex {
        case InputWire.eventQueue:
            more = endpoint.takeBuffers(from: elements, budget: CustomGPUDevice.turnBudget)
        case InputWire.statusQueue:
            more = endpoint.serveStatus(from: elements, budget: CustomGPUDevice.turnBudget)
            if endpoint.malformedStatusCount > 0 {
                troubles.notice(.malformed, "The guest's \(label) wrote a status message of the wrong length")
            }
        default:
            return
        }
        guard more, resuming.insert(queue.queueIndex).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            resuming.remove(queue.queueIndex)
            serveTurn(of: queue)
        }
    }

    /// The guest's queues are reset with the device: the buffers held are no longer on them, and giving one back would raise an
    /// exception in the framework, so they are let go. Events not yet delivered are stale and go with them.
    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        endpoint.forgetHeld()
    }

    /// The same when the machine stops: nothing is given back after it.
    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        endpoint.forgetHeld()
    }

    func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) {
        isPaused = true
    }

    func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) {
        isPaused = false
    }
}

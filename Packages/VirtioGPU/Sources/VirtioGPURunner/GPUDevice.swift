import Foundation
import Virtualization

/// The host side of the virtio GPU device. The framework calls it on the device queue, which is the main queue, so its
/// state is main-actor state. For now it records the device's life cycle and gives every element back unanswered: that
/// shows whether the guest finds the device, binds a driver and sends commands.
@available(macOS 27.0, *)
@MainActor
final class GPUDevice: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    private let started = ContinuousClock.now
    private var notifications = 0
    private var elements = 0

    /// One line, prefixed with the seconds since the device object was made.
    func log(_ text: String) {
        let elapsed = ContinuousClock.now - started
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        Output.line("[\(milliseconds / 1000).\(String(milliseconds % 1000 + 1000).dropFirst())] \(text)")
    }

    func customVirtioConfiguration(
        _ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice
    ) {
        device.delegate = self
        log("device created")
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        let features = device.negotiatedFeatures
        log("DRIVER_OK, negotiated features subset0 \(features?.subset0 ?? 0) subset1 \(features?.subset1 ?? 0)")
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        notifications += 1
        var drained = 0
        while let element = queue.nextElement() {
            drained += 1
            element.returnToQueue()
        }
        elements += drained
        log(
            "queue \(queue.queueIndex): \(drained) element(s) given back unanswered (\(notifications) notifications, \(elements) in all)"
        )
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) { log("device stopping") }
    func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) { log("device pausing") }
    func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) { log("device resuming") }
    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) { log("device reset") }
}

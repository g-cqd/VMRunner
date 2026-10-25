import Foundation
import VirtioGPU
import Virtualization

@available(macOS 27.0, *)
extension CustomGPUDevice {
    /// The device as the machine's configuration takes it (`customVirtioDevices`): the virtio GPU of the library's identity, a
    /// control and a cursor queue, only `VIRTIO_F_VERSION_1` offered (two-dimensional, no optional feature of its own), one
    /// scanout and no capability set, and no save and restore. The framework's provider keeps this object weakly, so whoever
    /// makes the machine holds it for as long as the machine lives. It touches none of the device's state, so it may be called
    /// off the main actor, with the rest of the machine's configuration.
    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let space = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
        return VZCustomVirtioDeviceConfiguration(
            deviceID: GPUWire.deviceID, pciClass: (GPUWire.pciClassID, GPUWire.pciSubclassID), queueCount: GPUWire.queueCount,
            versionOneSubset: GPUWire.versionOneFeatureSubset1, space: space.bytes, delegate: self)
    }
}

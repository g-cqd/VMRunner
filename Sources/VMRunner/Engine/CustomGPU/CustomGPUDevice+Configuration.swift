import Foundation
import VirtioGPU
import Virtualization

@available(macOS 27.0, *)
extension CustomGPUDevice {
    /// The device as the machine's configuration takes it (`customVirtioDevices`): the virtio GPU of the library's identity, a
    /// control and a cursor queue, only `VIRTIO_F_VERSION_1` offered (two-dimensional, no optional feature of its own), one
    /// scanout and no capability set, and no save and restore. The framework's provider keeps this object weakly, so whoever
    /// makes the machine holds it for as long as the machine lives.
    func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.supportsSaveRestore = false
        configuration.deviceID = GPUWire.deviceID
        configuration.virtioQueueCount = GPUWire.queueCount
        (configuration.pciClassID, configuration.pciSubclassID) = (GPUWire.pciClassID, GPUWire.pciSubclassID)
        configuration.mandatoryFeatures.subset1 = GPUWire.versionOneFeatureSubset1
        let space = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Data(space.bytes))
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: .main, delegate: self)
        return configuration
    }
}

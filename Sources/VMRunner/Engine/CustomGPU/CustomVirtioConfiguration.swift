import Foundation
import Virtualization

@available(macOS 27.0, *)
extension VZCustomVirtioDeviceConfiguration {
    /// The configuration of a device the host implements, as the machine's `customVirtioDevices` takes it: the identity the guest
    /// binds by, the queues, `VIRTIO_F_VERSION_1` alone (`versionOneSubset` is the upper half of the feature set, where bit 32
    /// is), the device-specific configuration space as it starts, no save and restore, and a provider that calls `delegate` on
    /// the main queue. The framework's provider holds the delegate weakly, so whoever builds the machine holds the device. It
    /// touches no state of the delegate, so it may be called off the main actor, with the rest of the machine's configuration.
    convenience init(
        deviceID: UInt16, pciClass: (id: UInt8, subclass: UInt8), queueCount: UInt16, versionOneSubset: UInt32, space: [UInt8],
        delegate: any VZCustomVirtioDeviceConfigurationDelegate
    ) {
        self.init()
        supportsSaveRestore = false
        self.deviceID = deviceID
        virtioQueueCount = queueCount
        (pciClassID, pciSubclassID) = (pciClass.id, pciClass.subclass)
        mandatoryFeatures.subset1 = versionOneSubset
        deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Data(space))
        provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: .main, delegate: delegate)
    }
}

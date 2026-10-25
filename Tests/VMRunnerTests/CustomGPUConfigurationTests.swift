import Foundation
import Testing
import Virtualization

@testable import VMRunner
@testable import VirtioGPU

/// The device the app makes for a Linux machine, as far as it can be seen without starting one: the configuration the
/// framework is given. The framework validates it when a machine is built, which needs the virtualization entitlement. The
/// custom virtio devices need macOS 27, so on an older host these tests are skipped.
@MainActor
struct CustomGPUConfigurationTests {
    nonisolated static let hostHasCustomDevices = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    @available(macOS 27.0, *)
    private func device() -> CustomGPUDevice {
        CustomGPUDevice(sinks: CustomGPUDevice.Sinks(showFrame: { _ in }, showCursor: { _ in }))
    }

    @Test(.enabled(if: hostHasCustomDevices))
    func theConfigurationIsAVirtioGPUOfTheLibrarysIdentityWithOnlyVersionOne() {
        guard #available(macOS 27.0, *) else { return }
        let configuration = device().makeConfiguration()
        #expect(configuration.deviceID == 16 && configuration.deviceID == GPUWire.deviceID)
        #expect(configuration.pciClassID == 0x03 && configuration.pciSubclassID == 0x80)
        #expect(configuration.virtioQueueCount == 2)
        #expect(configuration.mandatoryFeatures.subset0 == 0 && configuration.mandatoryFeatures.subset1 == 1)
        // The framework sets a few optional bits by itself (the real run negotiated indirect descriptors, event index and packed
        // rings); the device adds none of its own.
        let defaults = VZCustomVirtioDeviceConfiguration().optionalFeatures
        #expect(configuration.optionalFeatures.subset0 == defaults.subset0 && configuration.optionalFeatures.subset1 == defaults.subset1)
        #expect(!configuration.supportsSaveRestore)
        #expect(configuration.provider != nil)
    }

    @Test(.enabled(if: hostHasCustomDevices))
    func theConfigurationSpaceStartsWithOneScanoutNoCapabilitySetAndNoEvent() {
        guard #available(macOS 27.0, *) else { return }
        let data = device().makeConfiguration().deviceSpecificConfiguration?.configurationData
        #expect(data == Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]))
    }

    @Test(.enabled(if: hostHasCustomDevices))
    func aDisplaySizeOutsideTheLimitsIsRefusedWithoutAMachine() {
        guard #available(macOS 27.0, *) else { return }
        let gpu = device()
        let empty = gpu.requestDisplaySize(width: 0, height: 600)
        let tooBig = gpu.requestDisplaySize(width: 7680, height: 4320)
        let fine = gpu.requestDisplaySize(width: 3840, height: 2160)
        #expect(!empty && !tooBig)
        #expect(fine, "a size within the limits is taken, and no device is told yet")
    }
}

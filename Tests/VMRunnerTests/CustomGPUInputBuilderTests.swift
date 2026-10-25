import AppKit
import Testing
import Virtualization

@testable import VMRunner

/// A Linux machine on the custom GPU in the configuration the framework is given, for each input path, and the key that names
/// the path: the same part of the configuration as `CustomGPUBuilderTests` looks at, with no machine made.
@MainActor
struct CustomGPUInputBuilderTests {
    private let display = (width: 1280, height: 800)

    private func machine(gpu: GPUChoice) -> VMConfig {
        var config = VMConfig.new(name: "g", guest: .linux)
        config.gpu = gpu
        return config
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theVirtioPathHasTheGPUAndTwoInputDevicesAndNoUSBKeyboardOrPointer() throws {
        guard #available(macOS 27.0, *) else { return }
        let vz = VZVirtualMachineConfiguration()
        try ConfigurationBuilder.configureLinuxScreen(
            vz, machine(gpu: .custom), display, customGPU: CustomGPUSession(display: display, input: VirtioInputSurface()))
        #expect(vz.customVirtioDevices.map(\.deviceID) == [16, 18, 18], "the GPU, then the keyboard, then the pointer")
        #expect(vz.graphicsDevices.isEmpty)
        #expect(vz.keyboards.isEmpty && vz.pointingDevices.isEmpty, "the guest sees only virtio input")
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theFrameworksPathHasTheGPUAndTheUSBKeyboardAndPointer() throws {
        guard #available(macOS 27.0, *) else { return }
        let vz = VZVirtualMachineConfiguration()
        try ConfigurationBuilder.configureLinuxScreen(
            vz, machine(gpu: .custom), display, customGPU: CustomGPUSession(display: display, input: FrameworkInputSurface()))
        #expect(vz.customVirtioDevices.map(\.deviceID) == [16])
        #expect(vz.keyboards.count == 1 && vz.pointingDevices.count == 1)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func aMachineOnTheFrameworksGraphicsKeepsItsUSBInputWhateverSurfaceItIsGiven() throws {
        guard #available(macOS 27.0, *) else { return }
        let vz = VZVirtualMachineConfiguration()
        try ConfigurationBuilder.configureLinuxScreen(
            vz, machine(gpu: .apple), display, customGPU: CustomGPUSession(display: display, input: VirtioInputSurface()))
        #expect(vz.graphicsDevices.count == 1 && vz.customVirtioDevices.isEmpty)
        #expect(vz.keyboards.count == 1 && vz.pointingDevices.count == 1)
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theDeveloperDefaultNamesTheSurfaceAMachineGets() {
        guard #available(macOS 27.0, *) else { return }
        #expect(CustomGPUInputPath.framework.makeSurface() is FrameworkInputSurface)
        #expect(CustomGPUInputPath.virtio.makeSurface() is VirtioInputSurface)
        #expect(CustomGPUInputPath(storedValue: nil).makeSurface() is FrameworkInputSurface)
    }
}

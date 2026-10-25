import CoreGraphics
import Foundation
import Testing
import Virtualization

@testable import VMRunner

/// A Linux machine's screen in the configuration the framework is given, as far as it can be seen without a machine: the
/// framework validates a whole configuration only with the virtualization entitlement, which a test run does not have, so these
/// tests look at the part of the configuration the graphics choice decides. The custom virtio devices need macOS 27, so on an
/// older host the tests that make one are skipped.
@MainActor
struct CustomGPUBuilderTests {
    private let display = (width: 1280, height: 800)

    private func machine(gpu: GPUChoice) -> VMConfig {
        var config = VMConfig.new(name: "g", guest: .linux)
        config.gpu = gpu
        return config
    }

    @Test
    func theFrameworksOwnDeviceIsOneGraphicsDeviceWithOneScanoutAndNoCustomDevice() throws {
        let vz = VZVirtualMachineConfiguration()
        try ConfigurationBuilder.configureLinuxScreen(vz, machine(gpu: .apple), (1920, 1080), customGPU: nil)
        let graphics = try #require(vz.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)
        #expect(vz.graphicsDevices.count == 1)
        #expect(graphics.scanouts.map { [$0.widthInPixels, $0.heightInPixels] } == [[1920, 1080]])
        #expect(vz.keyboards.count == 1 && vz.pointingDevices.count == 1)
        if #available(macOS 27.0, *) { #expect(vz.customVirtioDevices.isEmpty) }
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theCustomGPUIsOneVirtioGPUAndNoFrameworkGraphicsDevice() throws {
        guard #available(macOS 27.0, *) else { return }
        let vz = VZVirtualMachineConfiguration()
        try ConfigurationBuilder.configureLinuxScreen(
            vz, machine(gpu: .custom), display, customGPU: CustomGPUSession(display: display))
        #expect(vz.graphicsDevices.isEmpty)
        #expect(vz.customVirtioDevices.map(\.deviceID) == [16])
        #expect(vz.keyboards.count == 1 && vz.pointingDevices.count == 1, "the machine keeps a keyboard and a pointer")
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func aMachineThatChoseTheFrameworksDeviceIgnoresACustomGPUItIsGiven() throws {
        guard #available(macOS 27.0, *) else { return }
        let vz = VZVirtualMachineConfiguration()
        try ConfigurationBuilder.configureLinuxScreen(
            vz, machine(gpu: .apple), display, customGPU: CustomGPUSession(display: display))
        #expect(vz.graphicsDevices.count == 1 && vz.customVirtioDevices.isEmpty)
    }

    @Test
    func aMachineSetToTheCustomGPUWithNoneToUseIsRefusedWithAReason() {
        let vz = VZVirtualMachineConfiguration()
        do {
            try ConfigurationBuilder.configureLinuxScreen(vz, machine(gpu: .custom), display, customGPU: nil)
            Issue.record("a machine set to the custom GPU was configured without one")
        } catch SetupError.unsupportedHost(let reason) {
            #expect(reason == "The custom GPU needs macOS 27 or later on the host.")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(vz.graphicsDevices.isEmpty, "no framework graphics device is added as a fallback")
    }

    @Test(.enabled(if: CustomGPUConfigurationTests.hostHasCustomDevices))
    func theGuestsDisplayStartsAtTheSizeTheStartChoseWithinWhatTheDeviceAllows() {
        guard #available(macOS 27.0, *) else { return }
        let sizes: [(asked: (width: Int, height: Int), shown: CGSize)] = [
            ((1280, 800), CGSize(width: 1280, height: 800)), ((3840, 2160), CGSize(width: 3840, height: 2160)),
            ((0, -5), CGSize(width: 1, height: 1)),
        ]
        for size in sizes {
            #expect(CustomGPUSession(display: size.asked).screen.displaySize == size.shown, "\(size.asked)")
        }
        let large = CustomGPUSession(display: (7680, 4320)).screen.displaySize
        #expect(Int(large.width * large.height) * 4 <= 64 << 20 && large.width > 5000, "an 8K display is scaled to fit one resource")
    }
}

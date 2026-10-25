import CoreGraphics
import VirtioGPU
import Virtualization

/// One machine's custom GPU: the device the guest talks to and the screen that device draws on. It is made on the main actor
/// when the machine is prepared, and whoever holds it keeps the device alive, because the framework's provider holds the
/// device weakly.
@available(macOS 27.0, *)
@MainActor
final class CustomGPUSession: CustomDisplaySource {
    let screen: CustomScreen
    let input: any GuestInputSurface
    private let device: CustomGPUDevice

    /// The display starts at `display`, brought within the library's limits (`GPULimits.fittingDisplay`). The keyboard and
    /// pointer go through `input`.
    init(display: (width: Int, height: Int), input: any GuestInputSurface = FrameworkInputSurface()) {
        self.input = input
        var limits = GPULimits()
        let size = limits.fittingDisplay(width: UInt32(clamping: display.width), height: UInt32(clamping: display.height))
        (limits.displayWidth, limits.displayHeight) = size
        let screen = CustomScreen(displaySize: CGSize(width: Int(size.width), height: Int(size.height)))
        self.screen = screen
        device = CustomGPUDevice(
            limits: limits, sinks: CustomGPUDevice.Sinks(showFrame: { screen.show($0) }, showCursor: { screen.show($0) }))
    }

    func requestDisplaySize(width: UInt32, height: UInt32) -> Bool {
        device.requestDisplaySize(width: width, height: height)
    }

    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        device.makeConfiguration()
    }

    nonisolated func makeInputConfigurations() -> [VZCustomVirtioDeviceConfiguration] {
        input.makeConfigurations()
    }
}

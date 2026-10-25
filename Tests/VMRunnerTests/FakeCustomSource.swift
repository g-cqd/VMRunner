import CoreGraphics
import Virtualization

@testable import VMRunner

/// A custom GPU for tests that need a machine to look as if it had one: a screen, and no device behind it.
@MainActor
final class FakeCustomSource: CustomDisplaySource {
    let screen = CustomScreen(displaySize: CGSize(width: 1280, height: 800))
    let inputSurface = FakeInputSurface()
    var input: any GuestInputSurface { inputSurface }
    /// Whether the device takes the sizes it is asked for.
    var accepts = true
    /// Every size asked for, in order, including the ones refused.
    private(set) var requests: [CGSize] = []

    func requestDisplaySize(width: UInt32, height: UInt32) -> Bool {
        requests.append(CGSize(width: Int(width), height: Int(height)))
        return accepts
    }

    @available(macOS 27.0, *)
    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        VZCustomVirtioDeviceConfiguration()
    }

    @available(macOS 27.0, *)
    nonisolated func makeInputConfigurations() -> [VZCustomVirtioDeviceConfiguration] { [] }
}

import CoreGraphics
import Virtualization

@testable import VMRunner

/// A custom GPU for tests that need a machine to look as if it had one: a screen, and no device behind it.
@MainActor
final class FakeCustomSource: CustomDisplaySource {
    let screen = CustomScreen(displaySize: CGSize(width: 1280, height: 800))

    @available(macOS 27.0, *)
    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        VZCustomVirtioDeviceConfiguration()
    }
}

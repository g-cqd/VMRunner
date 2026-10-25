import SwiftUI

/// Shows the screen of a machine whose graphics device is the custom GPU, and keeps the guest's display the size of the view
/// when the machine follows the window. The picture is drawn from the source's screen, which outlives the view: full screen
/// swaps this view for a new one, and the new one draws the same screen from its newest picture. The policy of the resize is
/// `DisplayFollower`, as for the framework's display.
struct CustomGPUDisplay: NSViewRepresentable {
    let source: any CustomDisplaySource
    let settings: MachineModel.DisplaySettings
    /// Told, for each resize the app asks of the guest, whether the guest answered it.
    let guestAnswered: (Bool) -> Void

    func makeCoordinator() -> DisplayResizer { DisplayResizer() }

    func makeNSView(context: Context) -> CustomGPUContainer {
        let container = CustomGPUContainer()
        container.onLayout = { [weak resizer = context.coordinator] size in
            resizer?.viewResized(to: size)
        }
        configure(container, resizer: context.coordinator)
        return container
    }

    func updateNSView(_ container: CustomGPUContainer, context: Context) {
        configure(container, resizer: context.coordinator)
    }

    static func dismantleNSView(_ container: CustomGPUContainer, coordinator: DisplayResizer) {
        container.gpuView.detach()
    }

    private func configure(_ container: CustomGPUContainer, resizer: DisplayResizer) {
        container.gpuView.show(source.screen)
        resizer.configure(
            source: source, scale: settings.scale, enabled: settings.resizer == .app,
            holdFor: settings.firmwareHoldRemaining(at: .now), guestAnswered: guestAnswered)
    }
}

/// The custom GPU's view, hosted like the framework's.
final class CustomGPUContainer: ScreenContainer {
    let gpuView: CustomGPUView

    init() {
        let view = CustomGPUView()
        gpuView = view
        super.init(hosting: view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CustomGPUContainer is created in code only") }
}

import SwiftUI

/// Shows the screen of a machine whose graphics device is the custom GPU. The picture is drawn from the source's screen, which
/// outlives the view: full screen swaps this view for a new one, and the new one draws the same screen from its newest picture.
struct CustomGPUDisplay: NSViewRepresentable {
    let source: any CustomDisplaySource

    func makeNSView(context: Context) -> CustomGPUContainer {
        let container = CustomGPUContainer()
        container.gpuView.show(source.screen)
        return container
    }

    func updateNSView(_ container: CustomGPUContainer, context: Context) {
        container.gpuView.show(source.screen)
    }

    static func dismantleNSView(_ container: CustomGPUContainer, coordinator: Void) {
        container.gpuView.detach()
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

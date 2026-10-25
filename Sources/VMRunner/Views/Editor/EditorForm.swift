import SwiftUI

/// The machine editor's grouped form, with its sections at the pane's leading edge.
///
/// A grouped form never draws a section wider than about 700 points. In a wider space it keeps that width and centres the
/// column, so in the detail pane (800 to 1,400 points) the sections float in the middle, while the New Machine sheet
/// (560 points) and Settings (520) fill their windows from the leading edge. This form adds a trailing content margin for
/// the width beyond that limit: the form lays out within its cap, the sections start at the leading edge, and the scroller
/// stays at the pane's edge.
struct EditorForm<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var width: CGFloat = 0

    /// The widest a grouped form gets before it centres its sections: about 696 points of section and a 23-point margin on
    /// each side. Measured on macOS 27 only; if a later system changes the cap, the sections are centred again inside the
    /// narrower area, not broken.
    static var maxWidth: CGFloat { 742 }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .contentMargins(.trailing, max(0, width - Self.maxWidth), for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
    }
}

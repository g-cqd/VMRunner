import SwiftUI

/// Screen count and size, pixel density, and how the guest display follows the window.
struct DisplaySection: View {
    let guest: GuestOS
    @Binding var choice: DisplayChoice
    @Binding var width: Int
    @Binding var height: Int
    @Binding var pixelsPerInch: Int
    @Binding var followsWindow: Bool
    @Binding var pixelsPerPoint: Int

    var body: some View {
        Section {
            resolutionRows
            if guest == .macOS {
                ValueStepper(
                    title: "Pixel density", value: $pixelsPerInch, range: EditorLimits.pixelsPerInch,
                    step: EditorLimits.pixelsPerInchStep, text: "\(pixelsPerInch) ppi"
                )
                .settingHelp(.pixelDensity)
            } else {
                Text(
                    "Linux starts at no more than 1280 pixels wide, in the shape of the window, so UEFI and GRUB text stays "
                        + "legible, then follows the window once the system runs. A fixed size keeps the same aspect ratio only if "
                        + "the window does. A suspended machine resumes at the size it started with. A text console (an installer or "
                        + "a server) cannot follow the window: switch the resizing below off for it."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Resize guest display with window", isOn: $followsWindow)
                .settingHelp(.resizeWithWindow)
            if guest == .linux, followsWindow {
                Picker("Guest pixels per point", selection: $pixelsPerPoint) {
                    Text("1× — legible text (recommended)").tag(1)
                    Text("2× — sharper, but text looks small unless the guest scales it").tag(2)
                }
                .settingHelp(.pixelsPerPoint)
            }
        } header: {
            HelpHeader("Display", topic: guest == .linux ? .linuxBootText : .resolution)
        }
    }

    @ViewBuilder
    private var resolutionRows: some View {
        Picker("Resolution", selection: $choice) {
            Text("Match window").tag(DisplayChoice.matchWindow)
            Divider()
            ForEach(DisplayPreset.all) { Text($0.label).tag(DisplayChoice.preset($0)) }
            Divider()
            Text("Custom").tag(DisplayChoice.custom)
        }
        .settingHelp(.resolution)
        if choice == .custom {
            ValueStepper(
                title: "Width", value: $width, range: EditorLimits.displayWidth, step: EditorLimits.displayWidthStep,
                text: "\(width) px"
            )
            ValueStepper(
                title: "Height", value: $height, range: EditorLimits.displayHeight, step: EditorLimits.displayHeightStep,
                text: "\(height) px"
            )
        }
    }
}

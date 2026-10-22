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
                Stepper(value: $pixelsPerInch, in: EditorLimits.pixelsPerInch, step: EditorLimits.pixelsPerInchStep) {
                    LabeledContent("Pixel density", value: "\(pixelsPerInch) ppi")
                }
                .settingHelp(.pixelDensity)
            } else {
                Text(
                    "Linux starts at no more than 1280 pixels wide, in the shape of the window, so UEFI and GRUB text stays "
                        + "legible, then follows the window once the system runs. A fixed size keeps the same aspect ratio only if "
                        + "the window does. A suspended machine resumes at the size it started with."
                )
                .font(.caption).foregroundStyle(.secondary)
                .settingHelp(.linuxBootText)
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
            HelpHeader("Display", topic: .resolution)
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
            Stepper(value: $width, in: EditorLimits.displayWidth, step: EditorLimits.displayWidthStep) {
                LabeledContent("Width", value: "\(width) px")
            }
            Stepper(value: $height, in: EditorLimits.displayHeight, step: EditorLimits.displayHeightStep) {
                LabeledContent("Height", value: "\(height) px")
            }
        }
    }
}

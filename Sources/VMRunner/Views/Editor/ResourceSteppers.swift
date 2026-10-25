import SwiftUI

/// CPU core and memory steppers, shared by the new-machine sheet and the settings form.
struct CoreAndMemorySteppers: View {
    @Binding var cpuCount: Int
    @Binding var memoryMiB: Int
    let memoryStepMiB: Int

    var body: some View {
        ValueStepper(title: "CPU cores", value: $cpuCount, range: ConfigurationBuilder.cpuRange, text: "\(cpuCount)")
            .settingHelp(.cpuCores)
        ValueStepper(
            title: "Memory", value: $memoryMiB, range: ConfigurationBuilder.memoryRangeMiB, step: memoryStepMiB,
            text: (Double(memoryMiB) / 1024).formatted(.number.precision(.fractionLength(0...1))) + " GiB"
        )
        .settingHelp(.memory)
    }
}

/// A row with a stepper: the title at the leading edge, and the current value just before the arrows at the trailing edge,
/// where a picker or a `LabeledContent` row puts its value. The stepper keeps the title for VoiceOver.
struct ValueStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let text: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(text).monospacedDigit()
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .accessibilityValue(text)
            }
        }
    }
}

import SwiftUI

/// CPU core and memory steppers, shared by the new-machine sheet and the settings form.
struct CoreAndMemorySteppers: View {
    @Binding var cpuCount: Int
    @Binding var memoryMiB: Int
    let memoryStepMiB: Int

    var body: some View {
        Stepper(value: $cpuCount, in: ConfigurationBuilder.cpuRange) {
            LabeledContent("CPU cores", value: "\(cpuCount)")
        }
        .settingHelp(.cpuCores)
        Stepper(value: $memoryMiB, in: ConfigurationBuilder.memoryRangeMiB, step: memoryStepMiB) {
            LabeledContent("Memory", value: (Double(memoryMiB) / 1024).formatted(.number.precision(.fractionLength(0...1))) + " GiB")
        }
        .settingHelp(.memory)
    }
}

import ArgumentParser
import Foundation

struct SarifCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sarif",
        abstract: "Print the findings of SARIF files as path:line: level [rule] message.",
        discussion:
            "The analyzer GitHub Actions emit SARIF only; CI summarizes it with this. It never fails: the analyzer step is the gate."
    )

    @Argument(help: "SARIF files.")
    var files: [String] = []

    func run() {
        for file in files {
            for line in SarifSummary.lines(forFileAt: file) {
                Output.out(line)
            }
        }
    }
}

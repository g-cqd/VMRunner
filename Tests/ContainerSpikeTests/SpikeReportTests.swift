import Foundation
import Testing

@testable import ContainerSpikeCore

struct SpikeReportTests {
    @Test
    func theVerdictComesFromTheExitStatusFirstAndTheArchitectureSecond() {
        let uname = "Linux cctl 6.12.28 #1 SMP aarch64 Linux\n"
        #expect(SpikeVerdict.evaluate(exitCode: 0, output: uname) == .passed)
        #expect(SpikeVerdict.evaluate(exitCode: 0, output: "Linux x86_64\n") == .unexpectedOutput)
        #expect(SpikeVerdict.evaluate(exitCode: 0, output: "") == .unexpectedOutput)
        #expect(SpikeVerdict.evaluate(exitCode: 127, output: uname) == .commandFailed(exitCode: 127))
        #expect(SpikeVerdict.evaluate(exitCode: -1, output: uname) == .commandFailed(exitCode: -1))
    }

    @Test
    func onlyAPassExitsZero() {
        #expect(SpikeVerdict.passed.processStatus == 0)
        #expect(SpikeVerdict.commandFailed(exitCode: 3).processStatus == SpikeStatus.failed)
        #expect(SpikeVerdict.unexpectedOutput.processStatus == SpikeStatus.failed)
        let statuses = [SpikeStatus.passed, SpikeStatus.failed, SpikeStatus.usage, SpikeStatus.setupFailed]
        #expect(Set(statuses).count == statuses.count, "each outcome has its own status")
    }

    @Test
    func theReportListsPhasesOutputStatusAndVerdict() {
        var report = SpikeReport()
        report.phases = [
            .init(name: "pull", duration: .milliseconds(1_234)),
            .init(name: "boot", duration: .seconds(2) + .milliseconds(5)),
        ]
        report.output = "Linux cctl aarch64 Linux\n"
        report.exitCode = 0
        report.verdict = .passed
        #expect(
            report.lines == [
                "pull-seconds: 1.23", "boot-seconds: 2.01", "output: Linux cctl aarch64 Linux", "exit-status: 0", "verdict: passed",
            ])
    }

    @Test
    func secondsAreRoundedHalfUpToTwoDecimals() {
        #expect(SpikeReport.seconds(.zero) == "0.00")
        #expect(SpikeReport.seconds(.milliseconds(5)) == "0.01")
        #expect(SpikeReport.seconds(.milliseconds(4)) == "0.00")
        #expect(SpikeReport.seconds(.milliseconds(9_999)) == "10.00")
        #expect(SpikeReport.seconds(.seconds(-3)) == "0.00")
    }

    @Test
    func aRunThatNeverStartedReportsThat() {
        #expect(SpikeReport().lines == ["output: ", "exit-status: none", "verdict: not reached"])
    }
}

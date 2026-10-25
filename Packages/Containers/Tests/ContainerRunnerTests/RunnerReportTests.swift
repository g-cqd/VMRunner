import Foundation
import Testing

@testable import ContainerRunnerCore

struct RunnerReportTests {
    @Test
    func theVerdictComesFromTheExitStatusFirstAndTheArchitectureSecond() {
        let uname = "Linux cctl 6.12.28 #1 SMP aarch64 Linux\n"
        #expect(RunnerVerdict.evaluate(exitCode: 0, output: uname) == .passed)
        #expect(RunnerVerdict.evaluate(exitCode: 0, output: "Linux x86_64\n") == .unexpectedOutput)
        #expect(RunnerVerdict.evaluate(exitCode: 0, output: "") == .unexpectedOutput)
        #expect(RunnerVerdict.evaluate(exitCode: 127, output: uname) == .commandFailed(exitCode: 127))
        #expect(RunnerVerdict.evaluate(exitCode: -1, output: uname) == .commandFailed(exitCode: -1))
    }

    private func status(_ verdict: RunnerVerdict?, network: NetworkVerdict? = nil) -> Int32 {
        var report = RunnerReport()
        report.verdict = verdict
        report.networkVerdict = network
        return report.processStatus
    }

    @Test
    func onlyAPassExitsZeroAndARunThatNeverReachedAVerdictIsASetupFailure() {
        #expect(status(.passed) == RunnerStatus.passed)
        #expect(status(.passed, network: .passed) == RunnerStatus.passed)
        #expect(status(.commandFailed(exitCode: 3)) == RunnerStatus.failed)
        #expect(status(.unexpectedOutput, network: .passed) == RunnerStatus.failed)
        #expect(status(.passed, network: .noFrames) == RunnerStatus.failed)
        #expect(status(nil) == RunnerStatus.setupFailed)
        #expect(status(nil, network: .noFrames) == RunnerStatus.setupFailed)
        let statuses = [RunnerStatus.passed, RunnerStatus.failed, RunnerStatus.usage, RunnerStatus.setupFailed]
        #expect(Set(statuses).count == statuses.count, "each outcome has its own status")
    }

    @Test
    func theNetworkCheckAddsItsFramesAndVerdictToTheReport() {
        var report = RunnerReport()
        report.verdict = .passed
        report.networkVerdict = .noFrames
        #expect(
            report.lines.suffix(3) == [
                "verdict: passed", "frames-seen: 0", "network-verdict: failed: no frame reached the host end of the link",
            ])
        report.frames = (0..<25).compactMap { _ in FrameSummary.parse([UInt8](repeating: 0, count: 60)) }
        #expect(report.lines.filter { $0.hasPrefix("frame: ") }.count == 20, "the listing is capped")
        #expect(report.lines.contains("frames-seen: 25"), "the count is not")
    }

    @Test
    func theReportListsPhasesOutputStatusAndVerdict() {
        var report = RunnerReport()
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
        #expect(RunnerReport.seconds(.zero) == "0.00")
        #expect(RunnerReport.seconds(.milliseconds(5)) == "0.01")
        #expect(RunnerReport.seconds(.milliseconds(4)) == "0.00")
        #expect(RunnerReport.seconds(.milliseconds(9_999)) == "10.00")
        #expect(RunnerReport.seconds(.seconds(-3)) == "0.00")
    }

    @Test
    func aCustomCommandPassesOnItsExitStatusAlone() {
        #expect(RunnerVerdict.evaluate(exitCode: 0, output: "", checksArchitecture: false) == .passed)
        #expect(RunnerVerdict.evaluate(exitCode: 0, output: "Linux x86_64\n", checksArchitecture: false) == .passed)
        #expect(RunnerVerdict.evaluate(exitCode: 2, output: "aarch64", checksArchitecture: false) == .commandFailed(exitCode: 2))
    }

    @Test
    func aStoppedRunHasItsOwnStatusWhateverElseHappened() {
        var report = RunnerReport()
        report.verdict = .passed
        report.stopped = true
        #expect(report.processStatus == RunnerStatus.stopped)
        #expect(RunnerStatus.stopped == 75)
        report.verdict = nil
        #expect(report.processStatus == RunnerStatus.stopped, "stopped before a verdict is not a setup failure")
        report.stopped = false
        #expect(report.processStatus == RunnerStatus.setupFailed)
        let statuses = [RunnerStatus.passed, RunnerStatus.failed, RunnerStatus.usage, RunnerStatus.setupFailed, RunnerStatus.stopped]
        #expect(Set(statuses).count == statuses.count)
    }

    @Test
    func aRunThatNeverStartedReportsThat() {
        #expect(RunnerReport().lines == ["output: ", "exit-status: none", "verdict: not reached"])
    }
}

import Foundation
import Testing

@testable import VMHelperCore

struct EventTests {
    @Test
    func anEventIsOneSortedJsonLineThatReadsBack() throws {
        let event = HelperEvent(.probe, time: 0.5, pid: 42, message: "opened /a/b", check: "read", verdict: .allowed)
        let line = try event.line()
        #expect(line == #"{"check":"read","event":"probe","message":"opened /a/b","pid":42,"time":0.5,"verdict":"allowed"}"#)
        #expect(!line.contains("\n"))
        #expect(HelperEvent.parse(lines: line + "\n") == [event])
    }

    @Test
    func theConsoleIsReportedReadyWithItsSocketBeforeTheMachineBoots() throws {
        let ready = HelperEvent(.consoleReady, time: 0.01, pid: 9, message: "/tmp/x/console.sock")
        #expect(try ready.line() == #"{"event":"consoleReady","message":"/tmp/x/console.sock","pid":9,"time":0.01}"#)
        let lines = try [ready, HelperEvent(.booting, time: 0.02, pid: 9)].map { try $0.line() }.joined(separator: "\n")
        #expect(HelperEvent.parse(lines: lines).map(\.event) == [.consoleReady, .booting])
    }

    @Test
    func aMessageWithNewlinesStaysOnOneLine() throws {
        let event = HelperEvent(.error, time: 1, pid: 1, message: "a\nb\r\nc")
        let line = try event.line()
        #expect(!line.contains("\n") && !line.contains("\r"))
        #expect(HelperEvent.parse(lines: line).first?.message == "a\nb\r\nc")
    }

    @Test
    func parsingSkipsLinesThatAreNotEventsAndKeepsTheOrder() throws {
        let first = try HelperEvent(.booting, time: 0.1, pid: 7).line()
        let last = try HelperEvent(.running, time: 2.9, pid: 7).line()
        let events = HelperEvent.parse(lines: "noise\n\(first)\n{\"event\":\"bogus\"}\n\n\(last)\n")
        #expect(events.map(\.event) == [.booting, .running])
        #expect(events.map(\.time) == [0.1, 2.9])
    }

    @Test
    func everyFailureMapsToItsOwnSysexitsStatus() {
        let failures: [(HelperFailure, Int32)] = [
            (.usage("u"), 64), (.invalidDescriptor("d"), 65), (.missingFile("f"), 66), (.configurationRejected("c"), 69),
            (.virtualMachine("v"), 70),
        ]
        for (failure, status) in failures {
            #expect(failure.exitStatus == status)
            #expect(!HelperFailure.meaning(ofStatus: status).hasPrefix("unexpected"))
        }
        #expect(Set(failures.map(\.1)).count == failures.count)
        #expect(HelperFailure.meaning(ofStatus: 0).hasPrefix("success"))
        #expect(HelperFailure.meaning(ofStatus: 134).contains("aborted"))
        #expect(HelperFailure.meaning(ofStatus: 3) == "unexpected status 3")
    }
}

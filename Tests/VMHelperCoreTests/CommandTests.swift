import Foundation
import Testing

@testable import VMHelperCore

struct CommandTests {
    @Test
    func eachCommandIsReadFromItsLineAndWrittenBackAsTheSameLine() throws {
        let commands: [(String, HelperCommand)] = [
            ("policy", .reloadPolicy(terminatingOpenFlows: true)), ("policy terminate", .reloadPolicy(terminatingOpenFlows: true)),
            ("policy keep", .reloadPolicy(terminatingOpenFlows: false)), ("statistics", .statistics),
        ]
        for (line, command) in commands {
            #expect(try HelperCommand.parse(line) == command, "\(line)")
            #expect(try HelperCommand.parse(command.line) == command, "\(command)")
        }
    }

    @Test
    func spacesAroundAndBetweenWordsDoNotMatter() throws {
        #expect(try HelperCommand.parse("  policy   keep \r\n") == .reloadPolicy(terminatingOpenFlows: false))
        #expect(try HelperCommand.parse("\tstatistics\t") == .statistics)
    }

    @Test
    func aBlankLineIsNotACommand() throws {
        #expect(try HelperCommand.parse("") == nil)
        #expect(try HelperCommand.parse("  \t ") == nil)
    }

    @Test
    func anythingElseIsRefusedWithAReasonThatNamesTheProblem() {
        let cases: [(String, String)] = [
            ("reboot", "unknown command 'reboot'"), ("policy later", "policy takes keep or terminate, not later"),
            ("policy keep now", "keep now"), ("statistics now", "takes no argument"), ("POLICY", "unknown command 'POLICY'"),
        ]
        for (line, expected) in cases {
            do {
                _ = try HelperCommand.parse(line)
                Issue.record("accepted \(line)")
            } catch {
                #expect(error.reason.contains(expected), "\(line): \(error.reason)")
            }
        }
    }

    @Test
    func theNewEventKindsAreOneJsonLineEach() throws {
        for kind in [HelperEvent.Kind.flow, .statistics, .policy] {
            let event = HelperEvent(kind, time: 1, pid: 3, message: "tcp opened", check: "x")
            #expect(HelperEvent.parse(lines: try event.line()) == [event], "\(kind)")
        }
    }
}

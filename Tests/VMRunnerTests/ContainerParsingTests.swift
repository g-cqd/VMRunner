import Foundation
import Testing

@testable import VMRunner

struct ContainerRunnerArgumentsTests {
    @Test func theCommandLineFollowsTheRunnersContract() {
        let spec = ContainerSpec(
            image: "docker.io/library/busybox:1.37", command: ["sh", "-c", "echo hi"],
            environment: [
                ContainerEnvironmentEntry(name: "B", value: "2"), ContainerEnvironmentEntry(name: "A", value: "x=y z"),
            ], cpus: 4, memoryMiB: 1024, network: .loopback)
        let arguments = ContainerRunnerArguments.make(for: spec, scratch: URL(fileURLWithPath: "/tmp/scratch"))
        #expect(
            arguments == [
                "/tmp/scratch", "--json", "--image", "docker.io/library/busybox:1.37", "--cpus", "4", "--memory", "1024",
                "--network", "loopback", "--env", "B=2", "--env", "A=x=y z", "--command", "sh", "--command", "-c", "--command",
                "echo hi",
            ])
    }

    @Test func aDefaultSpecHasNoEnvironmentAndNoCommand() {
        let arguments = ContainerRunnerArguments.make(for: ContainerSpec(), scratch: URL(fileURLWithPath: "/s"))
        #expect(
            arguments == [
                "/s", "--json", "--image", ContainerSpec.defaultImage, "--cpus", "2", "--memory", "512", "--network", "none",
            ])
    }

    @Test func aRunnerInheritsTheSearchPathTheHomeAndTheTemporaryFolderOnly() {
        let source = ["PATH": "/opt/bin", "HOME": "/Users/x", "TMPDIR": "/tmp/x/", "DYLD_INSERT_LIBRARIES": "/evil", "HTTPS_PROXY": "p"]
        #expect(
            ContainerRunnerArguments.minimalEnvironment(from: source) == ["PATH": "/opt/bin", "HOME": "/Users/x", "TMPDIR": "/tmp/x/"])
        #expect(ContainerRunnerArguments.minimalEnvironment(from: [:]) == ["PATH": "/usr/bin:/bin"])
    }
}

struct ContainerScratchTests {
    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func theFolderIsCreatedPrivateWithItsParents() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "a/container-scratch", directoryHint: .isDirectory)
        try ContainerScratch.prepare(folder)
        #expect(try permissions(of: folder) == 0o700)
    }

    @Test func anExistingFolderIsKeptAndMadePrivate() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "container-scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try Data("cache".utf8).write(to: folder.appending(path: "kernel"))
        try ContainerScratch.prepare(folder)
        #expect(try permissions(of: folder) == 0o700)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "kernel").path))
    }

    @Test func aLinkOrAFileInItsPlaceIsRefused() throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = root.appending(path: "file")
        try Data().write(to: file)
        #expect(throws: ContainerScratch.Refusal(path: link.path)) { try ContainerScratch.prepare(link) }
        #expect(throws: ContainerScratch.Refusal(path: file.path)) { try ContainerScratch.prepare(file) }
    }
}

struct ContainerEventParsingTests {
    private func parse(_ line: String) -> ContainerEvent? { ContainerEvent(line: Array(line.utf8)) }

    @Test func eachKindDecodes() {
        #expect(parse(#"{"event":"phase","name":"pull","seconds":1.5,"time":3}"#) == .phase(name: "pull", seconds: 1.5))
        #expect(parse(#"{"event":"output","stream":"stderr","text":"a\nb","time":1}"#) == .output(stream: .stderr, text: "a\nb"))
        #expect(parse(#"{"event":"exited","status":3,"time":1}"#) == .exited(status: 3))
        #expect(parse(#"{"event":"error","message":"no kernel","time":1}"#) == .error(message: "no kernel"))
        #expect(parse(#"{"event":"finished","status":75,"time":1}"#) == .finished(status: 75))
    }

    @Test func aLineThatIsNotAnEventDecodesToNothing() {
        #expect(parse("") == nil)
        #expect(parse("runner: starting") == nil)
        #expect(parse(#"["event"]"#) == nil)
        #expect(parse(#"{"event":"progress","seconds":1}"#) == nil)
        #expect(parse(#"{"event":"output","stream":"stdin","text":"x"}"#) == nil)
        #expect(parse(#"{"event":"output","stream":"stdout"}"#) == nil)
        #expect(parse(#"{"event":"exited"}"#) == nil)
        #expect(parse(#"{"event":"exited","status":99999999999}"#) == nil)
        #expect(parse(#"{"event":"phase","seconds":1}"#) == nil)
    }
}

struct RunnerLineSplitterTests {
    private func lines(_ chunks: [String], bound: Int = 1024) -> (lines: [String], dropped: Int) {
        var splitter = RunnerLineSplitter(maxLineBytes: bound)
        var result: [[UInt8]] = []
        for chunk in chunks { result += splitter.append(Array(chunk.utf8)) }
        result += splitter.finish()
        return (result.map { (String(bytes: $0, encoding: .utf8) ?? "") }, splitter.droppedLines)
    }

    @Test func aLineIsHeldUntilItsNewlineWhereverTheReadsEnd() {
        let text = "one\ntwo\n\nthree-é\nlast"
        let bytes = Array(text.utf8)
        for cut in 0...bytes.count {
            var splitter = RunnerLineSplitter()
            let result = splitter.append(Array(bytes[..<cut])) + splitter.append(Array(bytes[cut...])) + splitter.finish()
            #expect(result.map { (String(bytes: $0, encoding: .utf8) ?? "") } == ["one", "two", "three-é", "last"], "cut at \(cut)")
        }
    }

    @Test func aLineOverTheBoundIsDroppedWholeAndCounted() {
        let long = String(repeating: "x", count: 11)
        let result = lines(["ok\n", long, long, "\nafter\n", long + "\nlast"], bound: 10)
        #expect(result.lines == ["ok", "after", "last"])
        #expect(result.dropped == 2)
    }

    @Test func aLineExactlyAtTheBoundIsKept() {
        let result = lines([String(repeating: "x", count: 10) + "\n"], bound: 10)
        #expect(result.lines == [String(repeating: "x", count: 10)])
        #expect(result.dropped == 0)
    }

    @Test func anEndlessLineNeverGrowsTheBuffer() {
        var splitter = RunnerLineSplitter(maxLineBytes: 100)
        let chunk = [UInt8](repeating: 0x41, count: 4096)
        for _ in 0..<1000 { #expect(splitter.append(chunk).isEmpty) }
        #expect(splitter.finish().isEmpty)
        #expect(splitter.droppedLines == 1)
    }
}

@MainActor
struct ContainerLogTests {
    @Test func theOldestTextGoesFirstAndTheMarkerSaysHowMuch() {
        var text = BoundedText(limit: 10)
        text.append(Array("abcdefghij".utf8))
        #expect(text.markedText == "abcdefghij")
        text.append(Array("klm".utf8))
        // The excess is 3 bytes and a quarter of the limit goes with it.
        #expect(text.text == "fghijklm")
        #expect(text.droppedBytes == 5)
        #expect(text.markedText == "[dropped 5 bytes]\nfghijklm")
    }

    @Test func aFullTextIsCutOnceForEachQuarterOfTheLimitAppended() {
        var text = BoundedText(limit: 100)
        text.append([UInt8](repeating: 0x61, count: 101))
        #expect(text.text.utf8.count == 75)
        #expect(text.droppedBytes == 26)
        // Room for 25 more bytes: nothing is cut or copied until the limit is passed again.
        for _ in 0..<25 { text.append([0x62]) }
        #expect(text.text.utf8.count == 100)
        #expect(text.droppedBytes == 26)
        text.append([0x63])
        #expect(text.text.utf8.count == 75)
        #expect(text.droppedBytes == 52)
        #expect(text.text.hasSuffix("bc"))
    }

    @Test func aCutNeverSplitsACharacter() {
        var text = BoundedText(limit: 5)
        text.append(Array("éééé".utf8))
        #expect(text.text == "éé")
        #expect(text.droppedBytes == 4)
    }

    @Test func aChunkLargerThanTheLimitKeepsItsEnd() {
        let log = ContainerLog(limit: 4)
        log.apply(.output(stream: .stdout, text: "0123456789"))
        #expect(log.output.text == "789")
        #expect(log.output.droppedBytes == 7)
        #expect(log.output.markedText == "[dropped 7 bytes]\n789")
    }

    @Test func outputPassesTheConsoleFilterWithOneStateForEachStream() {
        let log = ContainerLog()
        // A title the container sets, a private mode, and a sequence cut between two chunks of one stream with the other
        // stream's chunk between them.
        log.apply(.output(stream: .stdout, text: "\u{1B}]0;title\u{7}hi \u{1B}[31mred\u{1B}[0m\u{1B}[?1049h"))
        log.apply(.output(stream: .stdout, text: "a\u{1B}[?10"))
        log.apply(.output(stream: .stderr, text: "X"))
        log.apply(.output(stream: .stdout, text: "49hb"))
        #expect(log.output.text == "hi redaXb")
    }

    @Test func phasesStatusesAndErrorsAreRecorded() {
        let log = ContainerLog()
        log.apply(.phase(name: "pull", seconds: 2))
        log.apply(.phase(name: "run", seconds: 0.5))
        log.apply(.exited(status: 3))
        log.apply(.error(message: "bad\u{1B}]0;x\u{7} thing"))
        log.apply(.finished(status: 1))
        #expect(log.phases == [.init(name: "pull", seconds: 2), .init(name: "run", seconds: 0.5)])
        #expect(log.containerStatus == 3)
        #expect(log.errors == ["bad thing"])
        #expect(log.finishedStatus == 1)
    }

    @Test func phasesAreCappedInNumberAndNameLength() {
        let log = ContainerLog()
        for index in 0..<(ContainerLog.maxPhases + 5) { log.apply(.phase(name: "p\(index)", seconds: 1)) }
        #expect(log.phases.count == ContainerLog.maxPhases)
        #expect(log.phases.last?.name == "p\(ContainerLog.maxPhases - 1)")
        let other = ContainerLog()
        other.apply(.phase(name: "\u{1B}]0;x\u{7}" + String(repeating: "n", count: 500), seconds: 1))
        #expect(other.phases.first?.name == String(repeating: "n", count: ContainerLog.maxPhaseNameCharacters))
    }

    @Test func errorsAreCappedInNumberAndLength() {
        let log = ContainerLog()
        for index in 0..<(ContainerLog.maxErrors + 5) { log.apply(.error(message: "e\(index)")) }
        #expect(log.errors.count == ContainerLog.maxErrors)
        let other = ContainerLog()
        other.apply(.error(message: String(repeating: "z", count: 5000)))
        #expect(other.errors.first?.count == ContainerLog.maxErrorCharacters)
    }

    @Test func diagnosticsAreFilteredAndBounded() {
        let log = ContainerLog()
        log.appendDiagnostics(Array("warn\u{1B}]0;x\u{7}ing\n".utf8))
        #expect(log.diagnostics.text == "warning\n")
        log.appendDiagnostics([UInt8](repeating: 0x41, count: ContainerLog.diagnosticsLimit + 10))
        #expect(log.diagnostics.text.utf8.count == ContainerLog.diagnosticsLimit - ContainerLog.diagnosticsLimit / 4)
        #expect(log.diagnostics.droppedBytes == 18 + ContainerLog.diagnosticsLimit / 4)
    }

    @Test func escapeSequencesAndLoneEscapesLeaveNoResidue() {
        let log = ContainerLog()
        log.apply(.output(stream: .stdout, text: "a\u{1B}[31mb\u{1B}]0;t\u{7}c\u{1B}"))
        #expect(log.output.text == "abc")
        #expect(!log.output.text.contains("\u{1B}"))
    }

    @Test func formatCharactersAreRemovedWhileOrdinaryTextPasses() {
        let log = ContainerLog()
        log.apply(.output(stream: .stdout, text: "x\u{202E}y\u{200B}z\u{2066}"))
        #expect(log.output.text == "xyz")
        log.apply(.output(stream: .stdout, text: "héllo 世界 ✓\n\tend"))
        #expect(log.output.text == "xyzhéllo 世界 ✓\n\tend")
    }

    @Test func carriageReturnsAreRemovedFromOutputAndDiagnostics() {
        let log = ContainerLog()
        log.apply(.output(stream: .stdout, text: "a\rb\n"))
        #expect(log.output.text == "ab\n")
        log.appendDiagnostics(Array("c\r\nd\u{8}".utf8))
        #expect(log.diagnostics.text == "c\nd")
    }

    @Test(
        arguments: [
            ("\u{1B}[31mred\u{1B}[0m", "red"),
            ("a\u{1B}[2;3Hb", "ab"),
            ("x\u{1B}[2Ky", "xy"),
            ("\u{1B}[?25lz\u{1B}[?25h", "z"),
            ("p\u{1B}[1;4mq\n\tr", "pq\n\tr"),
        ] as [(String, String)])
    func escapeSequencesOfEveryKindAreRemoved(text: String, expected: String) {
        let log = ContainerLog()
        log.apply(.output(stream: .stdout, text: text))
        #expect(log.output.text == expected)
    }

    @Test func aSequenceSplitBetweenEventsIsRemovedWhole() {
        let log = ContainerLog()
        log.apply(.output(stream: .stdout, text: "a\u{1B}[3"))
        log.apply(.output(stream: .stdout, text: "1mb"))
        #expect(log.output.text == "ab")
    }
}

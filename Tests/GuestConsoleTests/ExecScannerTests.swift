import Testing

@testable import GuestConsole

/// The marker scanner against transcripts of what a terminal sends back: the echoed command line, the start marker alone on
/// a line, the output and the end marker with its status. The transcript is cut into pieces every way the tests can think of.
struct ExecScannerTests {
    private let markers = ExecMarkers(nonce: "ab12")

    /// What a shell on a terminal sends for `command`, with echo, CRLF line ends and the prompt that follows.
    private func transcript(output: String, status: Int, echo: Bool = true, noise: String = "") -> [UInt8] {
        var text = noise
        if echo { text += "echo MARK_S_ab12; ls -l; echo MARK_E_ab12_$?\r\n" }
        text += "MARK_S_ab12\r\n"
        text += output.replacing("\n", with: "\r\n")
        text += "MARK_E_ab12_\(status)\r\nlocalhost:~# "
        return Array(text.utf8)
    }

    private func scan(_ chunks: [[UInt8]]) -> ExecScanner.Progress {
        var scanner = ExecScanner(markers: markers)
        var last = ExecScanner.Progress.needMore
        for chunk in chunks {
            last = scanner.feed(chunk)
            if case .finished = last { return last }
        }
        return last
    }

    @Test
    func theOutputAndTheStatusAreFoundInOneRead() {
        let result = scan([transcript(output: "total 0\nfile\n", status: 0)])
        #expect(result == .finished(ExecResult(output: "total 0\nfile\n", status: 0)))
    }

    @Test
    func aTerminalThatDoesNotEchoWorksToo() {
        let result = scan([transcript(output: "x\n", status: 3, echo: false)])
        #expect(result == .finished(ExecResult(output: "x\n", status: 3)))
    }

    @Test
    func theEchoedCommandLineIsNeverTakenForTheMarkers() {
        var scanner = ExecScanner(markers: markers)
        #expect(scanner.feed(Array("echo MARK_S_ab12; true; echo MARK_E_ab12_$?\r\n".utf8)) == .needMore)
        // Output that merely looks like the end marker, before the start marker, does not count either.
        #expect(scanner.feed(Array("MARK_E_ab12_0\r\n".utf8)) == .needMore)
    }

    @Test
    func outputWithoutATrailingNewlineIsKeptAsItIs() {
        let result = scan([Array("echo MARK_S_ab12; printf foo; echo MARK_E_ab12_$?\r\nMARK_S_ab12\r\nfooMARK_E_ab12_0\r\n".utf8)])
        #expect(result == .finished(ExecResult(output: "foo", status: 0)))
    }

    @Test
    func aCommandWithNoOutputGivesAnEmptyString() {
        #expect(scan([transcript(output: "", status: 1)]) == .finished(ExecResult(output: "", status: 1)))
    }

    @Test
    func emptyLinesInTheOutputSurvive() {
        let result = scan([transcript(output: "\n\na\n\n", status: 0)])
        #expect(result == .finished(ExecResult(output: "\n\na\n\n", status: 0)))
    }

    @Test
    func noiseBeforeAndInsideTheTranscriptIsIgnored() {
        let noise = "[ 12.5] eth0: link up\r\nMARK_S_zz99\r\nMARK_E_zz99_0\r\n"
        let result = scan([transcript(output: "ok\n", status: 7, noise: noise)])
        #expect(result == .finished(ExecResult(output: "ok\n", status: 7)))
    }

    @Test
    func aStatusIsOneToThreeDigits() {
        for status in [0, 9, 10, 127, 255] {
            #expect(scan([transcript(output: "", status: status)]) == .finished(ExecResult(output: "", status: Int32(status))))
        }
    }

    @Test
    func theResultWaitsForTheLineEndAfterTheStatus() {
        var scanner = ExecScanner(markers: markers)
        #expect(scanner.feed(Array("MARK_S_ab12\r\nout\r\nMARK_E_ab12_12".utf8)) == .needMore)
        // 125 is not 12: the status was still being read when the first piece ended.
        #expect(scanner.feed(Array("5\r\n".utf8)) == .finished(ExecResult(output: "out\n", status: 125)))
    }

    @Test
    func theTranscriptCutAtEveryPositionGivesTheSameResult() {
        let bytes = transcript(output: "line one\nline two\n", status: 42)
        let expected = ExecScanner.Progress.finished(ExecResult(output: "line one\nline two\n", status: 42))
        for cut in 0...bytes.count {
            #expect(scan([Array(bytes[0..<cut]), Array(bytes[cut...])]) == expected, "cut at \(cut)")
        }
    }

    @Test
    func theTranscriptInOneByteReadsGivesTheSameResult() {
        let bytes = transcript(output: "a\nb\n", status: 0)
        #expect(scan(bytes.map { [$0] }) == .finished(ExecResult(output: "a\nb\n", status: 0)))
    }

    @Test
    func randomChunkingsGiveTheSameResult() {
        var random = SeededGenerator(seed: 7)
        let output = (0..<200).map { "row \($0) of the listing" }.joined(separator: "\n") + "\n"
        let bytes = transcript(output: output, status: 5, noise: "booting\r\n")
        let expected = ExecScanner.Progress.finished(ExecResult(output: output, status: 5))
        for _ in 0..<200 {
            var chunks: [[UInt8]] = []
            var position = 0
            while position < bytes.count {
                let size = Int.random(in: 1...64, using: &random)
                chunks.append(Array(bytes[position..<min(position + size, bytes.count)]))
                position += size
            }
            #expect(scan(chunks) == expected)
        }
    }

    @Test
    func aStartMarkerSplitInsideItsNonceIsStillFound() {
        let result = scan([Array("echo x\r\nMARK_S_a".utf8), Array("b12\r".utf8), Array("\nhi\r\nMARK_E_ab12_0\r".utf8), Array("\n".utf8)])
        #expect(result == .finished(ExecResult(output: "hi\n", status: 0)))
    }

    @Test
    func aTerminalThatRedrawsTheEchoDoesNotConfuseTheScan() {
        // Line editing wraps a long echo with a carriage return and a space; the pieces still never match as markers.
        let echo = "echo MARK_S_ab12; run; echo \u{20}\r MARK_E_ab12_$?\r\n"
        let result = scan([Array((echo + "MARK_S_ab12\r\nr\r\nMARK_E_ab12_0\r\n").utf8)])
        #expect(result == .finished(ExecResult(output: "r\n", status: 0)))
    }

    @Test
    func aCommandThatNeverStopsPrintingIsCutOffAtTheLimit() {
        var scanner = ExecScanner(markers: markers, limit: 1_000)
        _ = scanner.feed(Array("MARK_S_ab12\r\n".utf8))
        var outcome = ExecScanner.Progress.needMore
        for _ in 0..<100 where outcome == .needMore { outcome = scanner.feed([UInt8](repeating: 0x61, count: 100)) }
        #expect(outcome == .overflow)
    }

    @Test
    func noiseThatNeverContainsTheMarkerDoesNotGrowWithoutBound() {
        var scanner = ExecScanner(markers: markers, limit: 1_000)
        for _ in 0..<100 { _ = scanner.feed([UInt8](repeating: 0x61, count: 100)) }
        #expect(scanner.received.count <= 1_000)
        // The marker still shows up when it finally arrives.
        let finished = scanner.feed(Array("\r\nMARK_S_ab12\r\nz\r\nMARK_E_ab12_0\r\n".utf8))
        #expect(finished == .finished(ExecResult(output: "z\n", status: 0)))
    }

    @Test
    func theLineTypedIntoTheGuestWrapsTheCommandInTheMarkers() {
        #expect(markers.line(for: "uname -a") == "echo MARK_S_ab12; uname -a; echo MARK_E_ab12_$?\n")
    }
}

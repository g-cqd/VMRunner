import Testing

@testable import GuestConsole

/// The filter as a stream: input cut anywhere gives the same output, its limits hold, and random input never gets a
/// forbidden byte through.
struct ConsoleOutputFilterStreamTests {
    private func filtered(_ bytes: [UInt8]) -> [UInt8] {
        var filter = ConsoleOutputFilter()
        return filter.pass(bytes[...])
    }

    /// The output when `bytes` arrives in pieces cut at `cuts` (indices into `bytes`, ascending).
    private func filtered(_ bytes: [UInt8], cutAt cuts: [Int]) -> [UInt8] {
        var filter = ConsoleOutputFilter()
        var output: [UInt8] = []
        var start = 0
        for cut in cuts + [bytes.count] {
            output += filter.pass(bytes[start..<cut])
            start = cut
        }
        return output
    }

    @Test(arguments: FilterVectors.all)
    func aRowCutAtAnyByteGivesTheSameOutput(_ vector: FilterVector) {
        for cut in 0...vector.input.count {
            #expect(filtered(vector.input, cutAt: [cut]) == vector.output, "cut at \(cut)")
        }
        #expect(
            filtered(vector.input, cutAt: Array(stride(from: 1, to: vector.input.count, by: 1))) == vector.output,
            "one byte at a time")
    }

    /// `ESC ]` opens a control string and each `ESC ] 0 ; a` inside it is a new opener. The openers share one budget of
    /// `stringLimit` skipped bytes: the 4096th skipped byte, the `0` of the 1366th repetition, ends the string, so `;a` reads as
    /// text and the input's `END` after it does too. Each opener used to restart the count, so `END` was swallowed.
    @Test
    func nestedOpenersShareTheControlStringsBudget() {
        let repeated = Array("\u{1B}]".utf8) + Array(String(repeating: "\u{1B}]0;a", count: 1_366).utf8) + Array("END".utf8)
        #expect(filtered(repeated) == Array(";aEND".utf8))
        #expect(filtered(repeated, cutAt: Array(stride(from: 97, to: repeated.count, by: 97))) == Array(";aEND".utf8))
    }

    @Test
    func aCharacterCutBetweenReadsArrivesWholeWithItsLastByte() {
        var filter = ConsoleOutputFilter()
        let face: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        #expect(filter.pass(face[0..<1]).isEmpty)
        #expect(filter.pass(face[1..<3]).isEmpty)
        #expect(filter.pass(face[3..<4]) == face)
        #expect(filter.pass(Array("ok".utf8)[...]) == Array("ok".utf8))
    }

    @Test
    func aSequenceCutBetweenReadsShowsNothingUntilItsEnd() {
        var filter = ConsoleOutputFilter()
        #expect(filter.pass(Array("ok\u{1B}[3".utf8)[...]) == Array("ok".utf8))
        #expect(filter.pass(Array("1mred".utf8)[...]) == Array("\u{1B}[31mred".utf8))
        #expect(filter.pass(Array("\u{1B}]52;c;".utf8)[...]).isEmpty)
        #expect(filter.pass(Array("b3duZWQ=\u{07}after".utf8)[...]) == Array("after".utf8))
        #expect(filter.pass([0xC2]).isEmpty)
        #expect(filter.pass(Array([0x9D] + Array("0;title".utf8))[...]).isEmpty)
        #expect(filter.pass(Array("\u{1B}\\shown".utf8)[...]) == Array("shown".utf8))
    }

    @Test
    func aControlStringWithNoEndIsGivenUpAtTheLimitAndTextReadsAgain() {
        let limit = ConsoleOutputFilter.stringLimit
        let opening = Array("\u{1B}]".utf8)
        let atLimit = opening + [UInt8](repeating: UInt8(ascii: "x"), count: limit) + Array("after".utf8)
        #expect(filtered(atLimit) == Array("after".utf8))
        #expect(filtered(atLimit, cutAt: Array(stride(from: 1_000, to: atLimit.count, by: 1_000))) == Array("after".utf8))
        let oneShort = opening + [UInt8](repeating: UInt8(ascii: "x"), count: limit - 1) + Array("Zafter".utf8)
        #expect(filtered(oneShort) == Array("after".utf8), "the byte that reaches the limit is still skipped")
        let ended = opening + [UInt8](repeating: UInt8(ascii: "x"), count: limit - 1) + Array("\u{07}after".utf8)
        #expect(filtered(ended) == Array("after".utf8))
        let endless = opening + [UInt8](repeating: UInt8(ascii: "x"), count: 1 << 20)
        #expect(filtered(endless).count == (1 << 20) - limit, "past the limit the bytes are text again")
    }

    @Test
    func aCSISequenceLongerThanTheLimitIsDroppedWhole() {
        let limit = ConsoleOutputFilter.sequenceLimit
        let longest = Array("\u{1B}[".utf8) + [UInt8](repeating: UInt8(ascii: "1"), count: limit - 3) + Array("m".utf8)
        #expect(filtered(longest + Array("Z".utf8)) == longest + Array("Z".utf8))
        let tooLong = Array("\u{1B}[".utf8) + [UInt8](repeating: UInt8(ascii: "1"), count: limit - 2) + Array("mZ".utf8)
        #expect(filtered(tooLong) == Array("Z".utf8))
        let huge = Array("\u{1B}[".utf8) + [UInt8](repeating: UInt8(ascii: ";"), count: 1 << 20) + Array("mZ".utf8)
        #expect(filtered(huge) == Array("Z".utf8))
    }

    @Test
    func c1ControlsAreRemovedInBothForms() {
        for code in UInt8(0x80)...UInt8(0x9F) {
            #expect(filtered([code] + Array("Z".utf8)) == Array("Z".utf8), "the single byte \(code)")
            #expect(filtered([0xC2, code]).isEmpty, "the UTF-8 form of \(code)")
        }
    }

    /// Random input, cut at random places: the output is never longer than the input, is safe (see `isSafe`), comes out the
    /// same however the input is cut, and does not change when filtered again.
    @Test
    func randomInputNeverGetsAForbiddenByteThrough() {
        var random = SeededGenerator(seed: 23)
        // The bytes that build sequences come often, so every state is reached.
        let alphabet: [UInt8] = [
            0x1B, 0x1B, 0x5B, 0x5D, 0x50, 0x5F, 0x07, 0x18, 0x5C, 0x3B, 0x3F, 0x31, 0x6D, 0x48, 0x68, 0x9B, 0xC2, 0xE2, 0x82, 0xAC,
            0x0A,
        ]
        for round in 0..<300 {
            let input = (0..<512).map { _ in
                random.next().isMultiple(of: 2)
                    ? alphabet[Int(random.next() % UInt64(alphabet.count))] : UInt8(truncatingIfNeeded: random.next())
            }
            let cuts = (0..<8).map { _ in Int(random.next() % 513) }.sorted()
            let output = filtered(input)
            #expect(output.count <= input.count, "round \(round)")
            #expect(Self.isSafe(output), "round \(round): \(output)")
            #expect(filtered(input, cutAt: cuts) == output, "round \(round), cut at \(cuts)")
            #expect(filtered(output) == output, "round \(round): filtered twice")
        }
    }

    /// With no `[` in the input no CSI sequence can form, so no ESC at all may reach the terminal.
    @Test
    func randomInputWithoutAnOpeningBracketNeverGetsAnEscapeThrough() {
        var random = SeededGenerator(seed: 41)
        for round in 0..<200 {
            let input = (0..<1_024).map { _ in UInt8(truncatingIfNeeded: random.next()) }.map { $0 == 0x5B ? 0x5A : $0 }
            let output = filtered(input)
            #expect(!output.contains(0x1B), "round \(round)")
            #expect(output.count <= input.count, "round \(round)")
            #expect(Self.isSafe(output), "round \(round)")
        }
    }

    @Test
    func theSameInputAlwaysGivesTheSameOutput() {
        var random = SeededGenerator(seed: 5)
        let input = (0..<65_536).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        let first = filtered(input)
        #expect(filtered(input) == first)
        #expect(filtered(input, cutAt: Array(stride(from: 7, to: input.count, by: 7))) == first)
    }

    /// A boot and a login as a serial console shows them, written by hand in the shape of a small distribution's: coloured
    /// service lines that move the cursor, a title and bracketed paste from the shell, a login prompt and shell prompts.
    private static let bootLog: [(text: String, kept: Bool)] = [
        ("[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x610f0000]\r\n", true),
        ("[    0.000000] Linux version 6.12.0-0-virt (builder@localhost) #1-Alpine SMP\r\n", true),
        ("\r\n   The init scripts are starting up Linux 6.12.0-0-virt (aarch64)\r\n\r\n", true),
        (" \u{1B}[32;01m*\u{1B}[0m Mounting /proc ...", true),
        ("\u{1B}[A\u{1B}[71G \u{1B}[34;01m[\u{1B}[32;01m ok \u{1B}[34;01m]\u{1B}[0m\r\n", true),
        (" \u{1B}[32;01m*\u{1B}[0m Starting networking ...", true),
        ("\u{1B}[A\u{1B}[71G \u{1B}[34;01m[\u{1B}[32;01m ok \u{1B}[34;01m]\u{1B}[0m\r\n", true),
        ("\r\nWelcome to Alpine Linux 3.22\r\nKernel 6.12.0-0-virt on an aarch64 (/dev/hvc0)\r\n\r\n", true),
        ("localhost login: ", true),
        ("root\r\n", true),
        ("Welcome to Alpine!\r\n\r\n", true),
        ("\u{1B}]0;root@localhost:~\u{07}", false),
        ("\u{1B}[?2004h", false),
        ("localhost:~# ", true),
        ("ls -la\r\n", true),
        ("\u{1B}[?2004l", false),
        ("total 8\r\ndrwx------    2 root     root          4096 Oct 23 10:00 \u{1B}[1;34m.\u{1B}[m\r\n", true),
        ("\u{1B}]0;root@localhost:~\u{1B}\\", false),
        ("\u{1B}[?2004h", false),
        ("localhost:~# ", true),
    ]

    @Test
    func aBootAndLoginLogIsUnchangedApartFromTheRemovedSequences() {
        let input = Self.bootLog.flatMap { Array($0.text.utf8) }
        let expected = Self.bootLog.filter { $0.kept }.flatMap { Array($0.text.utf8) }
        #expect(filtered(input) == expected)
        // The same log in 64-byte reads, as a slow line would deliver it.
        #expect(filtered(input, cutAt: Array(stride(from: 64, to: input.count, by: 64))) == expected)
    }

    /// Whether `output` is something the filter may let through: valid UTF-8; no C1 control, no DEL, and no C0 control but
    /// the five that pass and ESC; and every ESC the start of a whole CSI sequence the allow-list accepts.
    private static func isSafe(_ output: [UInt8]) -> Bool {
        guard let text = String(validating: output, as: UTF8.self) else { return false }
        let controls: Set<UInt32> = [0x07, 0x08, 0x09, 0x0A, 0x0D, 0x1B]
        for scalar in text.unicodeScalars where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
            guard controls.contains(scalar.value) else { return false }
        }
        var index = 0
        while let start = output[index...].firstIndex(of: 0x1B) {
            guard start + 1 < output.count, output[start + 1] == 0x5B,
                let end = output[(start + 2)...].firstIndex(where: { (0x40...0x7E).contains($0) }),
                ConsoleOutputFilter.allows(Array(output[start...end]))
            else { return false }
            index = end + 1
        }
        return true
    }
}

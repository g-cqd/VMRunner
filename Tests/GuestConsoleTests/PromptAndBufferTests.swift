import Testing

@testable import GuestConsole

struct PromptClassifierTests {
    private func classify(_ text: String) -> ConsolePrompt? {
        PromptClassifier.classify(Array(text.utf8))
    }

    @Test
    func aLoginPromptAtTheEndOfTheBootMessagesIsALogin() {
        #expect(classify("Welcome to Alpine Linux 3.22\r\nKernel 6.12 on aarch64 (/dev/hvc0)\r\n\r\nlocalhost login: ") == .login)
        #expect(classify("localhost login:") == .login)
        #expect(classify("LOGIN: ") == .login)
    }

    @Test
    func aPasswordPromptIsAPassword() {
        #expect(classify("localhost login: root\r\nPassword: ") == .password)
    }

    @Test
    func aShellPromptIsAShell() {
        #expect(classify("localhost:~# ") == .shell)
        #expect(classify("motd\r\nuser@host:~$ ") == .shell)
        #expect(classify("\u{1B}[1;32mroot@box\u{1B}[0m:~# ") == .shell)
    }

    @Test
    func aFinishedLineOrOutputInProgressIsNotAPrompt() {
        #expect(classify("") == nil)
        #expect(classify("localhost login: \r\n") == nil)
        #expect(classify("[    1.234] virtio_net: probed") == nil)
        #expect(classify("# a comment line\r\nmore output") == nil)
        #expect(classify("> ") == nil)  // a continuation prompt is not a ready shell
    }

    @Test
    func onlyTheEndOfLongOutputIsLookedAt() {
        let noise = String(repeating: "x", count: 10_000)
        #expect(classify(noise + "\r\nlocalhost:~# ") == .shell)
        #expect(classify("localhost login: " + noise) == nil)
    }

    @Test
    func invalidUtf8DoesNotTrap() {
        #expect(PromptClassifier.classify([0xFF, 0xFE, 0x23]) == .shell)
    }
}

struct ByteFIFOTests {
    @Test
    func bytesComeOutInTheOrderTheyWentIn() {
        var fifo = ByteFIFO(capacity: 8)
        #expect(fifo.append([1, 2, 3][...]) == 3)
        #expect(fifo.append([4, 5][...]) == 2)
        #expect(fifo.contents() == [1, 2, 3, 4, 5])
        fifo.discardFront(2)
        #expect(fifo.contents() == [3, 4, 5])
    }

    @Test
    func appendTakesOnlyWhatFits() {
        var fifo = ByteFIFO(capacity: 4)
        #expect(fifo.append([1, 2, 3][...]) == 3)
        #expect(fifo.append([4, 5, 6][...]) == 1)
        #expect(fifo.contents() == [1, 2, 3, 4])
        #expect(fifo.free == 0)
    }

    @Test
    func contentsSurviveTheWrapAround() {
        var fifo = ByteFIFO(capacity: 5)
        fifo.append([1, 2, 3, 4][...])
        fifo.discardFront(3)
        fifo.append([5, 6, 7, 8][...])
        #expect(fifo.contents() == [4, 5, 6, 7, 8])
        #expect(fifo.count == 5)
    }

    @Test
    func droppingOldestKeepsTheNewestBytes() {
        var fifo = ByteFIFO(capacity: 4)
        #expect(fifo.appendDroppingOldest([1, 2, 3][...]) == 0)
        #expect(fifo.appendDroppingOldest([4, 5][...]) == 1)
        #expect(fifo.contents() == [2, 3, 4, 5])
        // More than the capacity at once: only the last `capacity` bytes stay, and everything else counts as dropped.
        #expect(fifo.appendDroppingOldest([10, 11, 12, 13, 14, 15][...]) == 4 + 2)
        #expect(fifo.contents() == [12, 13, 14, 15])
    }

    @Test
    func theCapacityNeverGrows() {
        var fifo = ByteFIFO(capacity: 16)
        var random = SeededGenerator(seed: 3)
        var expected: [UInt8] = []
        for round in 0..<500 {
            let chunk = (0..<Int.random(in: 0...40, using: &random)).map { UInt8(truncatingIfNeeded: round &+ $0) }
            fifo.appendDroppingOldest(chunk[...])
            expected = Array((expected + chunk).suffix(16))
            #expect(fifo.contents() == expected)
            if round.isMultiple(of: 3) {
                let drop = Int.random(in: 0...5, using: &random)
                fifo.discardFront(drop)
                expected = Array(expected.dropFirst(drop))
            }
        }
    }
}

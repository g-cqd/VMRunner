import Foundation
import Testing

@testable import ContainerRunnerCore

struct RunnerEventTests {
    @Test
    func eachKindIsOneLineWithSortedKeys() throws {
        let lines = try [
            RunnerEvent(.phase, time: 1.5, name: "pull", seconds: 0.25).line(),
            RunnerEvent(.output, time: 2, stream: .stdout, text: "a/b\n\"q\"").line(),
            RunnerEvent(.output, time: 2.5, stream: .stderr, text: "").line(),
            RunnerEvent(.exited, time: 3, status: 7).line(),
            RunnerEvent(.error, time: 0.5, message: "pull failed").line(),
            RunnerEvent(.finished, time: 4, status: 75).line(),
        ]
        #expect(
            lines == [
                #"{"event":"phase","name":"pull","seconds":0.25,"time":1.5}"#,
                #"{"event":"output","stream":"stdout","text":"a/b\n\"q\"","time":2}"#,
                #"{"event":"output","stream":"stderr","text":"","time":2.5}"#,
                #"{"event":"exited","status":7,"time":3}"#,
                #"{"event":"error","message":"pull failed","time":0.5}"#,
                #"{"event":"finished","status":75,"time":4}"#,
            ])
        #expect(lines.allSatisfy { !$0.contains("\n") && !$0.contains("\\/") })
    }

    @Test
    func aLineDecodesBackToTheSameEvent() throws {
        let event = RunnerEvent(.output, time: 1.25, stream: .stderr, text: "héllo\u{1}")
        let decoded = try JSONDecoder().decode(RunnerEvent.self, from: Data(event.line().utf8))
        #expect(decoded == event)
    }

    @Test
    func aDurationBecomesFractionalSeconds() {
        #expect(RunnerEvent.seconds(of: .zero) == 0)
        #expect(RunnerEvent.seconds(of: .milliseconds(1_500)) == 1.5)
        #expect(RunnerEvent.seconds(of: .seconds(3)) == 3)
    }

    @Test
    func aLongWriteIsSplitAtTheChunkLimit() {
        let limit = RunnerEvent.maximumChunkBytes
        #expect(limit == 16384)
        #expect(RunnerEvent.chunks(of: Data()).isEmpty)
        #expect(RunnerEvent.chunks(of: Data(repeating: 1, count: limit)).map(\.count) == [limit])
        #expect(RunnerEvent.chunks(of: Data(repeating: 1, count: limit + 1)).map(\.count) == [limit, 1])
        #expect(RunnerEvent.chunks(of: Data(repeating: 1, count: 2 * limit + 5)).map(\.count) == [limit, limit, 5])
    }

    @Test
    func theChunksKeepTheBytesInOrderEvenForASlice() {
        let data = Data((0..<40_000).map { UInt8($0 % 251) })
        #expect(Data(RunnerEvent.chunks(of: data).joined()) == data)
        let slice = data[100...]
        #expect(Data(RunnerEvent.chunks(of: slice).joined()) == Data(slice))
    }

    /// What a fresh detector answers to each piece of input in turn.
    private func feeding(_ pieces: [String]) -> [Bool] {
        var detector = StopLineDetector()
        return pieces.map { detector.feed(Data($0.utf8)) }
    }

    @Test
    func theStopLineIsFoundWhereverTheBytesAreCut() {
        #expect(feeding(["st", "op", "\n"]) == [false, false, true], "no newline, no line")
        #expect(feeding(["stop\n"]) == [true])
        #expect(feeding(["  stop\r\n"]) == [true])
        #expect(feeding(["hello\nstop\nrest"]) == [true])
    }

    @Test
    func otherLinesAreIgnored() {
        let pieces = ["stopped\n", "STOP\n", "stop now\n", "\n", "xstop\n", "stop"]
        #expect(feeding(pieces) == Array(repeating: false, count: pieces.count))
    }

    @Test
    func aVeryLongLineIsDroppedWholeAndCannotHideOrFakeAStop() {
        let long = String(repeating: "x", count: 1000)
        #expect(feeding([long, "stop\n", "stop\n"]) == [false, false, true], "the tail of a long line is not a line of its own")
    }
}

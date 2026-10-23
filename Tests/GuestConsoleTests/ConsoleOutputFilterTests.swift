import Testing

@testable import GuestConsole

/// One row of the filter's table: what the guest sends, and what may reach the person's terminal.
struct FilterVector: Sendable, CustomTestStringConvertible {
    let name: String
    let input: [UInt8]
    let output: [UInt8]

    var testDescription: String { name }

    /// `sequence` between two letters vanishes whole: only the letters reach the terminal.
    static func removed(_ name: String, _ sequence: String) -> Self {
        removed(name, bytes: Array(sequence.utf8))
    }

    static func removed(_ name: String, bytes sequence: [UInt8]) -> Self {
        Self(name: name, input: Array("A".utf8) + sequence + Array("B".utf8), output: Array("AB".utf8))
    }

    /// `sequence` between two letters reaches the terminal unchanged.
    static func kept(_ name: String, _ sequence: String) -> Self {
        let bytes = Array(("A" + sequence + "B").utf8)
        return Self(name: name, input: bytes, output: bytes)
    }
}

/// The table: what a guest could send against the person's terminal, the edge cases of the grammar, and what a boot log, a
/// login prompt and a shell need.
enum FilterVectors {
    static let esc = "\u{1B}"
    static let bel = "\u{07}"
    /// The string terminator, ESC `\`.
    static let st = "\u{1B}\\"
    /// Every C1 control as a single byte.
    static let singleC1: [UInt8] = (0x80...0x9F).map { UInt8($0) }
    /// The C1 controls that open no sequence and no string, each in its UTF-8 form.
    static let quietC1InUTF8: [UInt8] = (0x80...0x9F).filter { ![0x90, 0x98, 0x9B, 0x9D, 0x9E, 0x9F].contains($0) }
        .flatMap { [0xC2, UInt8($0)] }
    /// Every printable ASCII character, space to tilde.
    static let printable = String((0x20...0x7E).map { Character(Unicode.Scalar(UInt8($0))) })

    /// Sequences a guest could use against the person's terminal; each one vanishes whole.
    static let removed: [FilterVector] = [
        .removed("OSC 0 window title ended by BEL", "\(esc)]0;owned\(bel)"),
        .removed("OSC 0 window title ended by ST", "\(esc)]0;owned\(st)"),
        .removed("OSC 1 icon name", "\(esc)]1;owned\(bel)"),
        .removed("OSC 2 window title", "\(esc)]2;owned\(st)"),
        .removed("OSC 52 clipboard write", "\(esc)]52;c;b3duZWQ=\(bel)"),
        .removed("OSC 52 clipboard read", "\(esc)]52;c;?\(bel)"),
        .removed("OSC 8 hyperlink", "\(esc)]8;;https://example.invalid/\(st)"),
        .removed("OSC 4 palette change", "\(esc)]4;1;rgb:ff/00/00\(bel)"),
        .removed("OSC 10 colour query", "\(esc)]10;?\(bel)"),
        .removed("OSC 7 working directory", "\(esc)]7;file://host/root\(st)"),
        .removed("OSC 777 notification", "\(esc)]777;notify;title;body\(bel)"),
        .removed("DCS DECRQSS query", "\(esc)P$qm\(st)"),
        .removed("DCS terminfo query", "\(esc)P+q544e\(st)"),
        .removed("DCS graphics", "\(esc)Pq#0;2;0;0;0#0~~\(st)"),
        .removed("APC graphics payload", "\(esc)_Gf=100;AAAA\(st)"),
        .removed("PM", "\(esc)^private\(st)"),
        .removed("SOS", "\(esc)Xstring\(st)"),
        .removed("DA1 request", "\(esc)[c"),
        .removed("DA1 request with 0", "\(esc)[0c"),
        .removed("DA2 request", "\(esc)[>c"),
        .removed("DA3 request", "\(esc)[=c"),
        .removed("DSR status report", "\(esc)[5n"),
        .removed("CPR cursor position report", "\(esc)[6n"),
        .removed("DECXCPR", "\(esc)[?6n"),
        .removed("DECRQM private mode query", "\(esc)[?2004$p"),
        .removed("DECRQM mode query", "\(esc)[4$p"),
        .removed("terminal version query", "\(esc)[>0q"),
        .removed("window title report", "\(esc)[21t"),
        .removed("window resize", "\(esc)[8;100;200t"),
        .removed("window iconify", "\(esc)[2t"),
        .removed("alternate screen 1049", "\(esc)[?1049h"),
        .removed("alternate screen 47", "\(esc)[?47h"),
        .removed("mouse reporting 1000", "\(esc)[?1000h"),
        .removed("mouse any-event reporting 1003", "\(esc)[?1003h"),
        .removed("mouse SGR encoding 1006", "\(esc)[?1006h"),
        .removed("bracketed paste", "\(esc)[?2004h"),
        .removed("focus reports", "\(esc)[?1004h"),
        .removed("application cursor keys", "\(esc)[?1h"),
        .removed("application keypad", "\(esc)="),
        .removed("cursor hidden", "\(esc)[?25l"),
        .removed("autowrap off", "\(esc)[?7l"),
        .removed("several private modes at once", "\(esc)[?1049;1000;2004h"),
        .removed("keyboard protocol push", "\(esc)[>1u"),
        .removed("keyboard protocol query", "\(esc)[?u"),
        .removed("insert mode", "\(esc)[4h"),
        .removed("line feed mode", "\(esc)[20h"),
        .removed("RIS full reset", "\(esc)c"),
        .removed("DECSTR soft reset", "\(esc)[!p"),
        .removed("scroll region", "\(esc)[1;5r"),
        .removed("erase the scrollback", "\(esc)[3J"),
        .removed("erase in display with two parameters", "\(esc)[2;3J"),
        .removed("selective erase in display", "\(esc)[?2J"),
        .removed("cursor style", "\(esc)[2 q"),
        .removed("DECSC save cursor", "\(esc)7"),
        .removed("DECRC restore cursor", "\(esc)8"),
        .removed("reverse index", "\(esc)M"),
        .removed("screen alignment fill", "\(esc)#8"),
        .removed("line drawing set as G0", "\(esc)(0"),
        .removed("line drawing set as G1", "\(esc))0"),
        .removed("repeat the last character", "\(esc)[999999b"),
        .removed("insert lines", "\(esc)[5L"),
        .removed("delete lines", "\(esc)[5M"),
        .removed("scroll up", "\(esc)[5S"),
        .removed("save cursor by CSI", "\(esc)[s"),
        .removed("SGR with a private marker", "\(esc)[>4;2m"),
        .removed("cursor movement with a private marker", "\(esc)[?5C"),
        .removed("shift out and shift in", "\u{0E}\u{0F}"),
        .removed("NUL", "\u{00}"),
        .removed("DEL", "\u{7F}"),
        .removed("vertical tab and form feed", "\u{0B}\u{0C}"),
        .removed("other C0 controls", "\u{01}\u{02}\u{03}\u{04}\u{05}\u{06}\u{10}\u{11}\u{1C}\u{1D}\u{1E}\u{1F}"),
        .removed("CSI cancelled by CAN", "\(esc)[31\u{18}"),
        .removed("OSC cancelled by SUB", "\(esc)]0;owned\u{1A}"),
        .removed("every C1 control as a single byte", bytes: singleC1),
        .removed("CSI in UTF-8 form", bytes: [0xC2, 0x9B] + Array("31m".utf8)),
        .removed("OSC in UTF-8 form", bytes: [0xC2, 0x9D] + Array("0;owned".utf8) + [0x07]),
        .removed("DCS in UTF-8 form", bytes: [0xC2, 0x90] + Array("$qm".utf8) + [0x1B, 0x5C]),
        .removed("APC in UTF-8 form", bytes: [0xC2, 0x9F] + Array("payload".utf8) + [0x1B, 0x5C]),
        .removed("NEL in UTF-8 form", bytes: [0xC2, 0x85]),
        .removed("the C1 controls that open nothing, in UTF-8 form", bytes: quietC1InUTF8),
        .removed("bytes that start no character", bytes: [0xFF, 0xC0, 0xC1, 0xF5, 0xFE]),
        .removed("lone continuation bytes", bytes: [0xA9, 0xBF]),
        .removed("an overlong form", bytes: [0xE0, 0x80, 0xAF]),
        .removed("a surrogate", bytes: [0xED, 0xA0, 0x80]),
        .removed("a code point above U+10FFFF", bytes: [0xF4, 0x90, 0x80, 0x80]),
    ]

    /// The grammar's edges: what a terminal would do, done the same way.
    static let edges: [FilterVector] = [
        FilterVector(
            name: "a hyperlink's text stays and its link goes",
            input: Array("\(esc)]8;;https://example.invalid/\(st)click\(esc)]8;;\(st)".utf8), output: Array("click".utf8)),
        FilterVector(name: "an escape takes the byte after it", input: Array("A\(esc)BC".utf8), output: Array("AC".utf8)),
        FilterVector(
            name: "a single 8-bit CSI byte goes alone and what follows is text, as on a UTF-8 terminal",
            input: [0x41, 0x9B] + Array("31mB".utf8), output: Array("A31mB".utf8)),
        FilterVector(
            name: "a control inside a CSI sequence acts and the sequence still ends",
            input: Array("\(esc)[1\n;31mX".utf8), output: Array("\n\(esc)[1;31mX".utf8)),
        FilterVector(
            name: "ESC inside a CSI sequence opens a new one", input: Array("\(esc)[31\(esc)[1mX".utf8),
            output: Array("\(esc)[1mX".utf8)),
        FilterVector(
            name: "ESC inside an OSC string that is not its end opens a new sequence", input: Array("\(esc)]0;t\(esc)[1mX".utf8),
            output: Array("\(esc)[1mX".utf8)),
        FilterVector(
            name: "a character cut short is dropped and the byte that cut it is kept", input: [0xE2, 0x82, 0x41],
            output: Array("A".utf8)),
        FilterVector(
            name: "an escape cuts a character short", input: [0xE2, 0x82, 0x1B, 0x5B, 0x6D], output: Array("\(esc)[m".utf8)),
    ]

    /// What a boot log, a login prompt and a shell's line editing use; each one reaches the terminal unchanged.
    static let kept: [FilterVector] = [
        .kept("SGR reset", "\(esc)[0m"),
        .kept("SGR reset without a parameter", "\(esc)[m"),
        .kept("SGR bold red", "\(esc)[1;31m"),
        .kept("SGR 256 colours", "\(esc)[38;5;208m"),
        .kept("SGR true colour", "\(esc)[38;2;10;20;30m"),
        .kept("SGR true colour with colons", "\(esc)[38:2::10:20:30m"),
        .kept("cursor up", "\(esc)[A"),
        .kept("cursor up 2", "\(esc)[2A"),
        .kept("cursor down", "\(esc)[B"),
        .kept("cursor forward 5", "\(esc)[5C"),
        .kept("cursor back", "\(esc)[D"),
        .kept("cursor to column 71", "\(esc)[71G"),
        .kept("cursor home", "\(esc)[H"),
        .kept("cursor to row 10 column 20", "\(esc)[10;20H"),
        .kept("cursor position by HVP", "\(esc)[1;1f"),
        .kept("erase below", "\(esc)[J"),
        .kept("erase below with 0", "\(esc)[0J"),
        .kept("erase above", "\(esc)[1J"),
        .kept("erase the display", "\(esc)[2J"),
        .kept("erase to the end of the line", "\(esc)[K"),
        .kept("erase to the start of the line", "\(esc)[1K"),
        .kept("erase the line", "\(esc)[2K"),
        .kept("delete characters", "\(esc)[3P"),
        .kept("insert characters", "\(esc)[2@"),
        .kept("erase characters", "\(esc)[4X"),
        .kept("line feed, carriage return, tab, backspace and bell", "\n\r\t\u{08}\u{07}"),
        .kept("UTF-8 in two, three and four bytes", "é€😀"),
        .kept("U+00A0, the first character after the C1 controls", "\u{A0}"),
        .kept("a clear screen as a shell sends it", "\(esc)[H\(esc)[2J"),
        .kept("every printable ASCII character", printable),
    ]

    static let all = removed + edges + kept
}

struct ConsoleOutputFilterTests {
    @Test(arguments: FilterVectors.all)
    func eachRowIsKeptOrRemovedAsTheTableSays(_ vector: FilterVector) {
        var filter = ConsoleOutputFilter()
        #expect(filter.pass(vector.input[...]) == vector.output)
    }

    @Test
    func theTableCoversAtLeastSixtyRemovedSequencesUnderUniqueNames() {
        #expect(FilterVectors.removed.count >= 60)
        #expect(Set(FilterVectors.all.map(\.name)).count == FilterVectors.all.count)
    }

    /// The classic fault is to drop ESC and show the rest of the sequence as text. Every removed sequence, one after the other
    /// with words between them, leaves exactly the words.
    @Test
    func removedSequencesInARowLeaveOnlyTheTextAroundThem() {
        var input: [UInt8] = []
        var expected: [UInt8] = []
        for (index, vector) in FilterVectors.removed.enumerated() {
            let word = Array(" w\(index) ".utf8)
            input += word + vector.input
            expected += word + vector.output
        }
        var filter = ConsoleOutputFilter()
        #expect(filter.pass(input[...]) == expected)
    }

    @Test
    func theAllowListTakesOnlyDigitsAndSeparatorsAndTheFinalBytesItNames() {
        let allowed = ["\u{1B}[1;31m", "\u{1B}[38:2::1:2:3m", "\u{1B}[10;20H", "\u{1B}[2J", "\u{1B}[K", "\u{1B}[3P"]
        let refused = [
            "\u{1B}[?25h", "\u{1B}[>c", "\u{1B}[3J", "\u{1B}[1:2H", "\u{1B}[ q", "\u{1B}[6n", "\u{1B}[r", "\u{1B}[", "\u{1B}m",
        ]
        for text in allowed { #expect(ConsoleOutputFilter.allows(Array(text.utf8)), "\(text.dropFirst())") }
        for text in refused { #expect(!ConsoleOutputFilter.allows(Array(text.utf8)), "\(text.dropFirst())") }
    }
}

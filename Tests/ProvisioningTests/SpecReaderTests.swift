import Testing

@testable import Provisioning

/// One refusal of the reader: the spec, the line it names (nil: the whole spec) and a fragment of its message.
struct ReaderRefusal: Sendable {
    let text: String
    let line: Int?
    let fragment: String

    init(_ text: String, _ line: Int?, _ fragment: String) {
        self.text = text
        self.line = line
        self.fragment = fragment
    }
}

let readerRefusals: [ReaderRefusal] = [
    ReaderRefusal("a: 1\n\tb: 2\n", 2, "a tab character"),
    ReaderRefusal("a: 1\r\nb: 2\n", 1, "carriage return"),
    ReaderRefusal("\u{FEFF}a: 1\n", 1, "byte order mark"),
    ReaderRefusal("---\na: 1\n", 1, "one document only"),
    ReaderRefusal("a: 1\n---\nb: 2\n", 2, "one document only"),
    ReaderRefusal("%YAML 1.2\na: 1\n", 1, "directives"),
    ReaderRefusal("a: &x 1\n", 1, "anchors"),
    ReaderRefusal("a: *x\n", 1, "aliases"),
    ReaderRefusal("a: !!str 1\n", 1, "tags"),
    ReaderRefusal("a: {b: 1}\n", 1, "flow collections"),
    ReaderRefusal("a: [1, 2]\n", 1, "flow collections"),
    ReaderRefusal("a: >\n  folded\n", 1, "folded blocks"),
    ReaderRefusal("a: |+\n  kept\n", 1, "only | and |-"),
    ReaderRefusal("a: |2\n  x\n", 1, "only | and |-"),
    ReaderRefusal("a: |\n", 1, "at least one line"),
    ReaderRefusal("a: 1\na: 2\n", 2, "appears twice"),
    ReaderRefusal("a:\nb: 1\n", 1, "a value is missing"),
    ReaderRefusal("a: b: c\n", 1, "cannot hold"),
    ReaderRefusal("a: 1\n  b: 2\n", 2, "unexpected indentation"),
    ReaderRefusal("a: 'open\n", 1, "must end on its line"),
    ReaderRefusal("a: \"\\x\"\n", 1, "inside double quotes"),
    ReaderRefusal("a: 'x' y\n", 1, "unexpected text after a quoted value"),
    ReaderRefusal("- a\n", 1, "not a list"),
    ReaderRefusal("  a: 1\n", 1, "must not be indented"),
    ReaderRefusal("", nil, "the spec is empty"),
    ReaderRefusal("# only a comment\n", nil, "the spec is empty"),
    ReaderRefusal("a:\n  - - b\n", 2, "a list starts on a line of its own"),
    ReaderRefusal("\"a\": 1\n", 1, "expected key: value"),
    ReaderRefusal("a: x\n<<: *b\n", 2, "expected key: value"),
    ReaderRefusal("a: @x\n", 1, "cannot start with @"),
]

struct SpecReaderTests {
    private func refusal(_ text: String, limits: ProvisioningLimits = .standard) throws -> ProvisioningError {
        try #require(throws: ProvisioningError.self) { try SpecReader.read(text, limits: limits) }
    }

    @Test
    func readsMapsListsAndBlocksWithTheirLines() throws {
        let node = try SpecReader.read(
            """
            a: one
            b:
              c: 'two'
              d:
              - three
              - e: four
                f: |-
                  five
                  six
            g: "seven"
            """)
        let expected = SpecNode.map(
            [
                SpecEntry(key: "a", line: 1, value: .text("one", line: 1)),
                SpecEntry(
                    key: "b", line: 2,
                    value: .map(
                        [
                            SpecEntry(key: "c", line: 3, value: .text("two", line: 3)),
                            SpecEntry(
                                key: "d", line: 4,
                                value: .list(
                                    [
                                        .text("three", line: 5),
                                        .map(
                                            [
                                                SpecEntry(key: "e", line: 6, value: .text("four", line: 6)),
                                                SpecEntry(key: "f", line: 7, value: .text("five\nsix", line: 7)),
                                            ], line: 6),
                                    ], line: 5)),
                        ], line: 3)),
                SpecEntry(key: "g", line: 10, value: .text("seven", line: 10)),
            ], line: 1)
        #expect(node == expected)
        #expect(node.line == 1)
    }

    @Test
    func aListMayStartAtItsKeysColumnOrBelowIt() throws {
        let atKeysColumn = try SpecReader.read("k:\n- x\n- y\n")
        let belowKey = try SpecReader.read("k:\n  - x\n  - y\n")
        #expect(atKeysColumn == belowKey)
    }

    @Test
    func everyScalarStaysText() throws {
        let node = try SpecReader.read("a: no\nb: 1.10\nc: null\nd: ~\ne: true\n")
        guard case .map(let entries, _) = node else {
            Issue.record("not a map: \(node)")
            return
        }
        #expect(
            entries.map(\.value) == [
                .text("no", line: 1), .text("1.10", line: 2), .text("null", line: 3), .text("~", line: 4), .text("true", line: 5),
            ])
    }

    @Test
    func quotedValuesKeepWhatTheyQuote() throws {
        let node = try SpecReader.read(
            #"""
            a: 'it''s # here'
            b: "tab\there \"q\" \\"
            c: 'x' # a comment
            """#)
        #expect(
            node
                == .map(
                    [
                        SpecEntry(key: "a", line: 1, value: .text("it's # here", line: 1)),
                        SpecEntry(key: "b", line: 2, value: .text("tab\there \"q\" \\", line: 2)),
                        SpecEntry(key: "c", line: 3, value: .text("x", line: 3)),
                    ], line: 1))
    }

    @Test
    func commentsAreDroppedButAHashInsideAWordIsText() throws {
        let node = try SpecReader.read("# heading\na: x # note\n\n   # indented comment\nb: x#y\n")
        #expect(
            node
                == .map(
                    [
                        SpecEntry(key: "a", line: 2, value: .text("x", line: 2)),
                        SpecEntry(key: "b", line: 5, value: .text("x#y", line: 5)),
                    ], line: 2))
    }

    @Test
    func aLiteralBlockKeepsItsTextTabsAndInnerBlankLines() throws {
        let clipped = try SpecReader.read("a: |\n  #!/bin/sh\n  echo\tx\n\n  # kept\n\n\nb: |-\n    one\n      two\n")
        #expect(
            clipped
                == .map(
                    [
                        SpecEntry(key: "a", line: 1, value: .text("#!/bin/sh\necho\tx\n\n# kept\n", line: 1)),
                        SpecEntry(key: "b", line: 8, value: .text("one\n  two", line: 8)),
                    ], line: 1))
    }

    @Test(arguments: readerRefusals)
    func refusesWithTheLine(_ given: ReaderRefusal) throws {
        let error = try refusal(given.text)
        #expect(error.line == given.line, "\(error)")
        #expect(error.message.contains(given.fragment), "\(error)")
    }

    // MARK: Limits

    @Test
    func aSpecAtTheSizeLimitIsReadAndOneByteMoreIsRefused() throws {
        var limits = ProvisioningLimits.standard
        limits.maxSpecBytes = 5
        let atLimit = try SpecReader.read("a: 1\n", limits: limits)
        #expect(atLimit == .map([SpecEntry(key: "a", line: 1, value: .text("1", line: 1))], line: 1))
        limits.maxSpecBytes = 4
        let error = try refusal("a: 1\n", limits: limits)
        #expect(error.line == nil)
        #expect(error.message == "the spec is 5 bytes; the limit is 4")
    }

    @Test
    func nestingAtTheDepthLimitIsReadAndOneLevelMoreIsRefused() throws {
        let text = "a:\n  b:\n    c: x\n"
        var limits = ProvisioningLimits.standard
        limits.maxDepth = 3
        _ = try SpecReader.read(text, limits: limits)
        limits.maxDepth = 2
        let error = try refusal(text, limits: limits)
        #expect(error.line == 3)
        #expect(error.message == "nested deeper than 2 levels")
    }
}

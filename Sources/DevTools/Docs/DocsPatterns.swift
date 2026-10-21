import RegexBuilder

/// The patterns of the documentation checks. `Regex` is not `Sendable`, so they are held by the checker that uses
/// them (built once per run) instead of in global state.
struct DocsPatterns {
    private let digit = CharacterClass("0"..."9")
    private let slug = Regex {
        OneOrMore(CharacterClass(("a"..."z"), ("0"..."9")))
        ZeroOrMore {
            "-"
            OneOrMore(CharacterClass(("a"..."z"), ("0"..."9")))
        }
    }

    /// Exactly `count` digits, captured as a number.
    private func number(_ count: Int) -> Regex<(Substring, Int)> {
        Regex {
            TryCapture {
                Repeat(digit, count: count)
            } transform: {
                Int($0)
            }
        }
    }

    // MARK: Names and headings

    /// `YYYY-MM-DD`, capturing the year, the month and the day.
    var date: Regex<(Substring, Int, Int, Int)> {  // swiftlint:disable:this large_tuple
        Regex {
            number(4)
            "-"
            number(2)
            "-"
            number(2)
        }
    }

    /// `NNNN-kebab-title.md`, capturing the number.
    var numberedName: Regex<(Substring, Substring)> {
        Regex {
            Capture { Repeat(digit, count: 4) }
            "-"
            slug
            ".md"
        }
    }

    /// `# NNNN — Title`, capturing the number.
    var numberedHeading: Regex<(Substring, Substring)> {
        Regex {
            "# "
            Capture { Repeat(digit, count: 4) }
            " — "
            OneOrMore(.any)
        }
    }

    /// `YYYY-MM-DD-NN.md`, capturing the date and the session number.
    var diaryName: Regex<(Substring, Int, Int, Int, Int)> {  // swiftlint:disable:this large_tuple
        Regex {
            date
            "-"
            number(2)
            ".md"
        }
    }

    /// `# Diary — YYYY-MM-DD (N)`, capturing the date and the session number.
    var diaryHeading: Regex<(Substring, Int, Int, Int, Int)> {  // swiftlint:disable:this large_tuple
        Regex {
            "# Diary — "
            date
            " ("
            TryCapture {
                OneOrMore(digit)
            } transform: {
                Int($0)
            }
            ")"
        }
    }

    /// `topic-YYYY-MM.md`, capturing the year and the month.
    var researchName: Regex<(Substring, Int, Int)> {  // swiftlint:disable:this large_tuple
        Regex {
            slug
            "-"
            number(4)
            "-"
            number(2)
            ".md"
        }
    }

    // MARK: References

    /// `ADR-NNNN`, capturing the number.
    var adrReference: Regex<(Substring, Substring)> {
        Regex {
            "ADR-"
            Capture { Repeat(digit, count: 4) }
        }
    }

    /// `roadmap NNNN`, capturing the number.
    var roadmapReference: Regex<(Substring, Substring)> {
        Regex {
            "roadmap "
            Capture { Repeat(digit, count: 4) }
        }
    }

    // MARK: Links

    var codeSpan: Regex<Substring> {
        Regex {
            "`"
            ZeroOrMore(CharacterClass.anyOf("`").inverted)
            "`"
        }
    }

    /// `](target` of an inline link or image: the target ends at the first space or closing parenthesis.
    var inlineTarget: Regex<(Substring, Substring)> {
        Regex {
            "]("
            Capture { OneOrMore(CharacterClass.anyOf(") \t").inverted) }
        }
    }

    /// `[label]: target` at the start of a line (footnotes, `[^1]: ...`, are not links).
    var definitionTarget: Regex<(Substring, Substring)> {
        Regex {
            Anchor.startOfLine
            ZeroOrMore(" ")
            "["
            NegativeLookahead { "^" }
            OneOrMore(CharacterClass.anyOf("]").inverted)
            "]:"
            OneOrMore(.horizontalWhitespace)
            Capture { OneOrMore(CharacterClass.whitespace.inverted) }
        }
    }
}

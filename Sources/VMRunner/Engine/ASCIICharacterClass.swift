import RegexBuilder

/// ASCII-only character classes for the RegexBuilder patterns that validate untrusted text. The built-in
/// `.digit`, `.hexDigit` and `.word` also accept other scripts and full-width forms, which a file name or a
/// checksum must never contain.
extension RegexComponent where Self == CharacterClass {
    static var asciiDigit: CharacterClass { CharacterClass("0"..."9") }

    static var asciiHexDigit: CharacterClass { CharacterClass("0"..."9", "a"..."f", "A"..."F") }

    static var asciiAlphanumeric: CharacterClass { CharacterClass("0"..."9", "a"..."z", "A"..."Z") }
}

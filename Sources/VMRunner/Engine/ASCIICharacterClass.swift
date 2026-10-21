import RegexBuilder

/// ASCII-only character classes for the RegexBuilder patterns that validate untrusted text. The built-in
/// `.digit`, `.hexDigit` and `.word` also accept other scripts and full-width forms, which a file name or a
/// checksum must never contain.
extension RegexComponent where Self == CharacterClass {
    static var asciiDigit: CharacterClass { CharacterClass("0"..."9") }

    static var asciiHexDigit: CharacterClass { CharacterClass("0"..."9", "a"..."f", "A"..."F") }

    static var asciiAlphanumeric: CharacterClass { CharacterClass("0"..."9", "a"..."z", "A"..."Z") }
}

extension String {
    private static let lowercaseHexDigits = Set("0123456789abcdef".utf8)

    /// Whether the text is exactly `digits` lowercase hexadecimal digits. The bytes are judged, so a look-alike character, a
    /// full-width digit or a digit with a combining mark never passes.
    func isLowercaseHexadecimal(digits: Int) -> Bool {
        utf8.count == digits && utf8.allSatisfy(Self.lowercaseHexDigits.contains)
    }
}

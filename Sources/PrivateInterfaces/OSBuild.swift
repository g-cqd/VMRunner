import Foundation

/// A macOS build as `kern.osversion` reports it, such as `26A434`: the Darwin major version, a capital letter, the build
/// count, and on a beta a trailing small letter that does not take part in the order.
package struct OSBuild: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let letter: Character
    let count: Int

    package init(major: Int, letter: Character, count: Int) {
        self.major = major
        self.letter = letter
        self.count = count
    }

    /// `nil` unless `text` is digits, one capital letter, digits and at most one small letter, in that order.
    package init?(_ text: String) {
        let characters = Array(text)
        guard let letterIndex = characters.firstIndex(where: { !$0.isASCIIDigit }), letterIndex > 0 else { return nil }
        let letter = characters[letterIndex]
        guard letter.isASCII, letter.isUppercase else { return nil }
        var end = letterIndex + 1
        while end < characters.count, characters[end].isASCIIDigit { end += 1 }
        guard end > letterIndex + 1 else { return nil }
        let suffix = characters[end...]
        guard suffix.isEmpty || (suffix.count == 1 && suffix[end].isASCII && suffix[end].isLowercase) else { return nil }
        guard let major = Int(String(characters[..<letterIndex])), let count = Int(String(characters[(letterIndex + 1)..<end]))
        else { return nil }
        self.init(major: major, letter: letter, count: count)
    }

    package var description: String { "\(major)\(letter)\(count)" }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.letter, lhs.count) < (rhs.major, rhs.letter, rhs.count)
    }

    /// The build this Mac is running, or `nil` when the system does not say.
    package static var running: String? {
        var size = 0
        guard unsafe sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard unsafe sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

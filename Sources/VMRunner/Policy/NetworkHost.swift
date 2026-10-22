import Foundation

/// Why a user-written rule (address, domain, or URL prefix) was rejected. Each case carries the offending text.
enum NetworkPolicyError: Error, Hashable, Sendable {
    case empty
    case invalidAddress(String)
    case invalidPrefixLength(String)
    case invalidDomain(String)
    /// A domain rule that is really an IP address in some spelling (`127.1`, `2130706433`, `[::1]`); use an address rule.
    case domainLooksLikeAddress(String)
    case invalidURL(String)
    /// URL prefix rules are enforceable for `http` only; an `https` path is invisible to a host-side proxy.
    case unsupportedScheme(String)
    /// Credentials, query, or fragment in a URL prefix rule.
    case unsupportedURLComponent(String)
    /// Not a port (1...65535) or a `low-high` range.
    case invalidPort(String)
    /// A connection rule with broken brackets or an empty port list.
    case invalidConnection(String)
}

extension NetworkPolicyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty: "The rule is empty."
        case .invalidAddress(let text): "\"\(text)\" is not a valid IP address or CIDR block."
        case .invalidPrefixLength(let text): "\"\(text)\" has an invalid prefix length."
        case .invalidDomain(let text): "\"\(text)\" is not a valid domain name or *.suffix pattern."
        case .domainLooksLikeAddress(let text): "\"\(text)\" is an IP address; add it as an address rule."
        case .invalidURL(let text): "\"\(text)\" is not a valid http URL prefix."
        case .unsupportedScheme(let scheme):
            "URL rules need the http scheme (\"\(scheme)\" paths cannot be seen through a CONNECT proxy); block the domain instead."
        case .unsupportedURLComponent(let component): "A URL rule cannot contain \(component)."
        case .invalidPort(let text): "\"\(text)\" is not a port (1-65535) or a range like 8000-8100."
        case .invalidConnection(let text): "\"\(text)\" is not a valid connection rule like example.com:443 or [2001:db8::/32]:443."
        }
    }
}

/// A host as the policy sees it: either an IP address or a normalized DNS name.
///
/// Parsing is deliberately strict, because every lenient spelling is a filter bypass:
/// - IPv4 must be canonical dotted-quad. A name whose *last label is numeric* (decimal digits, or `0x` plus hex digits)
///   is an IPv4 spelling to any resolver, so it is either canonical or rejected as ``ParseError/nonCanonicalAddress``.
///   That covers `2130706433`, `0x7f000001`, `0177.0.0.1`, `127.1`, and `010.0.0.1` (octal or decimal? ambiguous).
/// - IPv6 may be bracketed and may carry a zone identifier, which is dropped (the address decides).
/// - Names are ASCII only (`xn--` for IDNs): lower-cased, one trailing dot removed, no empty labels, labels of
///   1...63 characters from `a-z 0-9 - _`, no leading or trailing hyphen, 253 characters at most. Anything else,
///   including `%` escapes and full-width look-alikes, is malformed.
enum HostForm: Hashable, Sendable {
    case address(IPAddress)
    /// Lower-case, no trailing dot.
    case name(String)

    enum ParseError: Error, Hashable, Sendable {
        case malformed
        case nonCanonicalAddress
    }

    /// - Throws: ``ParseError/malformed`` or ``ParseError/nonCanonicalAddress``.
    init(parsing raw: String) throws(ParseError) {
        var text = Substring(raw)
        let bracketed = text.hasPrefix("[") && text.hasSuffix("]") && text.count >= 2
        if bracketed { text = text.dropFirst().dropLast() }
        if bracketed || text.contains(":") {
            let unzoned = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let address = IPAddress(strictLiteral: String(unzoned)), case .v6 = address else { throw .malformed }
            self = .address(address)
            return
        }
        if text.hasSuffix(".") { text = text.dropLast() }
        guard Self.isValidName(text) else { throw .malformed }
        let name = text.lowercased()
        guard Self.endsInNumber(name) else {
            self = .name(name)
            return
        }
        guard let address = IPAddress(strictLiteral: name), case .v4 = address else { throw .nonCanonicalAddress }
        self = .address(address)
    }

    private static func isValidName(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 253 else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { byte in
                switch byte {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x5F: true
                default: false
                }
            }
        }
    }

    /// WHATWG's "ends in a number" test: the last label is all decimal digits, or `0x` followed by hex digits.
    private static func endsInNumber(_ name: String) -> Bool {
        guard let last = name.split(separator: ".", omittingEmptySubsequences: false).last else { return false }
        if last.utf8.allSatisfy({ (0x30...0x39).contains($0) }) { return true }
        guard last.hasPrefix("0x") else { return false }
        return last.dropFirst(2).utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// Percent-decoding that undoes layered encoding, so `%2561` cannot hide an `a`.
enum PercentDecoding {
    /// Decodes `%HH` escapes repeatedly until the text stops changing. Invalid escapes (`%zz`, a trailing `%`)
    /// are left as they are; invalid UTF-8 produced by decoding becomes U+FFFD.
    ///
    /// - Returns: `nil` if the text still changes after 8 rounds (pathological nesting), which callers treat as malformed.
    static func decodeToFixedPoint(_ text: String) -> String? {
        var current = text
        for _ in 0..<8 {
            let next = decodeOnce(current)
            if next == current { return current }
            current = next
        }
        return nil
    }

    private static func decodeOnce(_ text: String) -> String {
        let input = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == 0x25, index + 2 < input.count,
                let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2])
            {
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(input[index])
                index += 1
            }
        }
        // Lossy on purpose; `output` is [UInt8], not Data, so the optional-conversion rule does not apply.
        return String(decoding: output, as: UTF8.self)  // swiftlint:disable:this optional_data_string_conversion
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

/// Canonical form of a URL path, for prefix matching.
///
/// Normalization is chosen to over-match rather than under-match, because path rules only ever *deny*:
/// escapes are decoded to a fixed point (so `/ad%6Din` and `/%2561dmin` are `/admin`); `\` is a separator;
/// empty and `.` segments vanish and `..` pops (it cannot climb above the root); `;parameters` are cut from each
/// segment (`/admin;x=1`); trailing dots and spaces are trimmed from a segment (`/admin.` on Windows servers);
/// and everything is lower-cased (some servers are case-insensitive). The cost is occasionally blocking a path a
/// case-sensitive server would treat as different.
enum URLPath {
    /// - Returns: the normalized segments, or `nil` when the path contains control characters (including `%00`),
    ///   or never stops decoding. Callers treat `nil` as malformed.
    static func normalizedSegments(_ percentEncodedPath: String) -> [String]? {
        guard let decoded = PercentDecoding.decodeToFixedPoint(percentEncodedPath),
            !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        var segments: [String] = []
        for piece in decoded.unicodeScalars.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }) {
            let segment = cleaned(String(String.UnicodeScalarView(piece)))
            switch segment {
            case "", ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(segment)
            }
        }
        return segments
    }

    private static func cleaned(_ raw: String) -> String {
        var segment = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        segment = segment.trimmingCharacters(in: .whitespaces)
        if segment == "." || segment == ".." { return segment }
        while let last = segment.last, last == "." || last == " " { segment.removeLast() }
        return segment.lowercased()
    }

    /// Re-encodes one normalized segment so a rule's text form parses back to the same segments.
    static func encode(_ segment: String) -> String {
        var output = ""
        for byte in segment.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                output.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                output += (byte < 16 ? "%0" : "%") + String(byte, radix: 16, uppercase: true)
            }
        }
        return output
    }
}

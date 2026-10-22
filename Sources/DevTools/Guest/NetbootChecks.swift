import Foundation

/// The checks a fetched netboot archive passes before anything in it is used. Each is a pure function over text the
/// vendor's files or a tool printed, so each can be tested without a network or a tool.
enum NetbootChecks {
    // MARK: Checksum

    /// The digest in a GNU-style checksum file (`<64 hex digits>  <file name>`) for exactly `archive`.
    static func digest(inChecksumFile text: String, for archive: String) throws -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count == 1, let line = lines.first else {
            throw ToolError("the checksum file for \(archive) has \(lines.count) lines; expected one")
        }
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard fields.count == 2 else { throw ToolError("the checksum file for \(archive) is not '<digest>  <file>'") }
        let digest = fields[0].lowercased()
        let name = fields[1].drop { $0 == "*" || $0 == " " }
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw ToolError("the checksum file for \(archive) does not start with a SHA-256 digest")
        }
        guard name == archive else { throw ToolError("the checksum file names \(name), not \(archive)") }
        return digest
    }

    // MARK: Signature

    /// The fingerprints of the primary keys in `gpg --with-colons --show-keys --fingerprint` output: the `fpr` line that
    /// follows each `pub` line, not those of the subkeys after it.
    static func primaryFingerprints(inColonListing text: String) -> [String] {
        var fingerprints: [String] = []
        var awaiting = false
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            guard let kind = fields.first else { continue }
            if kind == "pub" {
                awaiting = true
            } else if kind == "fpr", awaiting, fields.count > 9 {
                fingerprints.append(String(fields[9]).uppercased())
                awaiting = false
            } else if kind == "sub" || kind == "uid" {
                awaiting = false
            }
        }
        return fingerprints
    }

    /// Whether `gpg --status-fd` output reports a good signature made by the primary key with exactly `fingerprint`, and
    /// nothing in it says the signature, the key or the check is bad, expired or revoked.
    static func isGoodSignature(fromStatus text: String, by fingerprint: String) -> Bool {
        let wanted = fingerprint.uppercased()
        var good = false
        var valid = false
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("[GNUPG:] ") {
            let fields = line.dropFirst("[GNUPG:] ".count).split(separator: " ")
            guard let kind = fields.first else { continue }
            switch kind {
            case "GOODSIG": good = true
            case "VALIDSIG":
                // VALIDSIG <signing key> <date> <time> <expiry> <version> <reserved> <pk algo> <hash algo> <class> <primary key>
                valid = fields.count >= 11 && fields[10].uppercased() == wanted
            case "BADSIG", "EXPSIG", "EXPKEYSIG", "REVKEYSIG", "ERRSIG", "NO_PUBKEY", "KEYEXPIRED", "KEYREVOKED":
                return false
            default: break
            }
        }
        return good && valid
    }

    // MARK: Archive listing

    /// What is wrong with a `tar -tv` listing, one message per entry: only regular files and directories are acceptable, with
    /// relative names that stay inside the directory they are unpacked into.
    static func problems(inTarListing text: String) -> [String] {
        var problems: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            // mode, links, owner, group, size, month, day, time or year, then the name (which may hold spaces).
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard fields.count == 9, let type = fields[0].first else {
                problems.append("unreadable listing line: \(line.prefix(80))")
                continue
            }
            let name = String(fields[8])
            if type != "-" && type != "d" {
                problems.append("\(name): a \(describe(type: type)), not a plain file or directory")
            }
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                problems.append("\(name): leaves the directory it is unpacked into")
            }
            if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                problems.append("a name with a control character")
            }
        }
        return problems
    }

    private static func describe(type: Character) -> String {
        switch type {
        case "l": "symbolic link"
        case "h": "hard link"
        case "c", "b": "device"
        case "p": "named pipe"
        case "s": "socket"
        default: "special entry '\(type)'"
        }
    }
}

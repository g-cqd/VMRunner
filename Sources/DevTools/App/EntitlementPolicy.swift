import Foundation

/// What the app may be signed with, written here and not read from the entitlement files: a signature is judged against
/// this policy as well as against the file it was signed with, because a file that adds a relaxation and then signs
/// with it would otherwise agree with its own signature.
enum EntitlementPolicy {
    /// Every key the app may carry, with its one permitted value: the virtualization and microphone entitlements and the
    /// hardened-process (Enhanced Security) family `VMRunner.hardened.entitlements` enables.
    static let allowed: [String: PlistValue] = [
        "com.apple.security.virtualization": .bool(true),
        "com.apple.security.device.audio-input": .bool(true),
        "com.apple.security.hardened-process": .bool(true),
        "com.apple.security.hardened-process.enhanced-security-version-string": .string("2"),
        "com.apple.security.hardened-process.hardened-heap": .bool(true),
        "com.apple.security.hardened-process.dyld-ro": .bool(true),
        "com.apple.security.hardened-process.platform-restrictions-string": .string("2"),
    ]

    /// Relaxations that are named so the message says what they do; anything else outside `allowed` is "not allowed".
    /// `get-task-allow` is a debug-build entitlement: allowed there, refused in a release.
    private static let relaxations: [(prefix: String, meaning: String)] = [
        ("com.apple.security.cs.", "relaxes the hardened runtime"),
        ("com.apple.security.temporary-exception.", "is a sandbox exception"),
    ]

    /// What is wrong with a set of entitlements, whichever way it was obtained (a file or a signature).
    static func problems(in entitlements: Entitlements.Dictionary, isRelease: Bool) -> [String] {
        var problems: [String] = []
        for (key, value) in entitlements.sorted(by: { $0.key < $1.key }) {
            if let permitted = allowed[key] {
                if value != permitted { problems.append("\(key) is \(value); the policy allows only \(permitted)") }
            } else if key == Entitlements.getTaskAllow {
                if isRelease { problems.append("get-task-allow is present in a release build") }
            } else if let relaxation = relaxations.first(where: { key.hasPrefix($0.prefix) }) {
                problems.append("\(key) \(relaxation.meaning) and is not permitted")
            } else {
                problems.append("\(key) is not in the entitlement allowlist (EntitlementPolicy.allowed)")
            }
        }
        return problems
    }

    /// Double hyphens inside XML comments, as `path:line: message`: the kernel's entitlement parser rejects them, and the
    /// signature then fails at launch rather than at build time.
    static func commentProblems(in text: String, name: String) -> [String] {
        var problems: [String] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<!--", range: cursor..<text.endIndex) {
            let close = text.range(of: "-->", range: open.upperBound..<text.endIndex)
            let body = text[open.upperBound..<(close?.lowerBound ?? text.endIndex)]
            if let hyphens = body.range(of: "--") {
                let line = text[..<hyphens.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                problems.append("\(name):\(line): a double hyphen inside an XML comment (the kernel's entitlement parser rejects it)")
            } else if body.hasSuffix("-") {
                // "--->" ends the comment with a hyphen that pairs with the two of its terminator.
                problems.append("\(name): an XML comment ends in a hyphen (the kernel's entitlement parser rejects it)")
            }
            guard let close else { break }
            cursor = close.upperBound
        }
        return problems
    }
}

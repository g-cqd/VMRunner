import Foundation

/// What must be true before a release ships, and is deliberately not true of a private working repository: the
/// `.github/CODEOWNERS` owner is a placeholder GitHub ignores (an unresolved owner protects nothing) and the bundle
/// identifier is under `com.example.`. Only the release workflow runs this step; the fast and full gates do not, so
/// ordinary CI stays green until the repository is published.
enum Publication {
    static let ownerPlaceholder = "@OWNER"
    static let placeholderBundlePrefix = "com.example."
    static let codeownersPath = ".github/CODEOWNERS"
    static let infoPlistPath = "Resources/Info.plist"

    /// Everything that still reads as a placeholder under `root`, as `path[:line]: message`.
    static func problems(root: URL) -> [String] {
        codeownersProblems(root: root) + bundleIdentifierProblems(root: root)
    }

    private static func codeownersProblems(root: URL) -> [String] {
        guard let text = try? String(contentsOf: root.appending(path: codeownersPath), encoding: .utf8) else {
            return ["\(codeownersPath): cannot read it, so no change has a review owner"]
        }
        var problems: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            // A pattern, then its owners; everything from `#` on is a comment.
            let code = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            if code.split(whereSeparator: \.isWhitespace).dropFirst().contains(where: { $0 == ownerPlaceholder }) {
                problems.append("\(codeownersPath):\(index + 1): the owner \(ownerPlaceholder) is a placeholder that GitHub ignores")
            }
        }
        return problems
    }

    private static func bundleIdentifierProblems(root: URL) -> [String] {
        struct Bundle: Decodable {
            let identifier: String

            enum CodingKeys: String, CodingKey {
                case identifier = "CFBundleIdentifier"
            }
        }
        guard let data = try? Data(contentsOf: root.appending(path: infoPlistPath)),
            let identifier = (try? PropertyListDecoder().decode(Bundle.self, from: data))?.identifier
        else {
            return ["\(infoPlistPath): cannot read a CFBundleIdentifier"]
        }
        guard identifier.hasPrefix(placeholderBundlePrefix) else { return [] }
        return ["\(infoPlistPath): CFBundleIdentifier \(identifier) is a placeholder under \(placeholderBundlePrefix)"]
    }

    @Sendable
    static func run(_ context: StepContext) async throws {
        let problems = problems(root: context.root)
        for problem in problems {
            Output.err(problem)
        }
        guard problems.isEmpty else {
            throw ToolError("publication: \(problems.count) placeholder(s) left; a release must not ship with them")
        }
        Output.out("publication: no placeholder left")
    }
}

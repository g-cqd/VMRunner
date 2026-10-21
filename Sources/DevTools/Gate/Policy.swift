import Foundation

/// Changes that make the gate easier to pass and that a green run would not notice: a baseline that accepts more
/// findings, a lower coverage floor, a SwiftLint rule turned off, a `.gitattributes` line that collapses a file out of
/// the review diff. They are compared with the base of the branch (`origin/main`, or the merge base with it) and fail
/// unless acknowledged, in a place the reviewer sees: a `Policy-Ack: <reason>` trailer in a commit message the branch
/// adds, or `VMR_POLICY_ACK=<reason>` in the environment for a local run. Without `origin/main` (a fresh clone, no
/// remote) there is nothing to compare with and the step says so and passes.
enum Policy {
    static let baselineFiles = [".arcleak-baseline.json", ".dolly-baseline.json", ".deadwood-baseline.json"]
    static let acknowledgementVariable = "VMR_POLICY_ACK"
    static let trailerName = "Policy-Ack"

    /// `-diff` and `binary` (which implies it) hide a file's changes from a diff; `linguist-generated` collapses them.
    private static let hidingAttributes: Set<String> = ["-diff", "binary", "linguist-generated", "linguist-generated=true"]

    /// A baseline file's accepted findings.
    private struct Baseline: Decodable {
        let fingerprints: [String]
    }

    @Sendable
    static func run(_ context: StepContext) async throws {
        let git = Git(directory: context.root)
        guard let base = await baseRevision(git: git) else {
            Output.out("policy: no origin/main to compare with (a fresh clone or no remote); nothing checked")
            return
        }
        let problems = try await self.problems(root: context.root, base: base, git: git)
        guard !problems.isEmpty else {
            Output.out("policy: nothing relaxed since \(base.prefix(12))")
            return
        }
        for problem in problems {
            Output.err("policy: \(problem)")
        }
        if let reason = await acknowledgement(environment: context.environment, base: base, git: git) {
            Output.out("policy: \(problems.count) relaxation(s) acknowledged: \(reason)")
            return
        }
        throw ToolError(
            "policy: \(problems.count) relaxation(s) of the gate; fix them, or acknowledge them with a '\(trailerName): <reason>' "
                + "trailer in a commit message or \(acknowledgementVariable)=<reason> for a local run")
    }

    // MARK: Comparison

    /// What the working tree relaxes compared with `base`.
    static func problems(root: URL, base: String, git: Git) async throws -> [String] {
        var problems: [String] = []
        for file in baselineFiles {
            let now = try Self.entries(at: root.appending(path: file))
            let before = await Self.entries(inText: baseText(file, base: base, git: git))
            let added = now.subtracting(before)
            if !added.isEmpty {
                problems.append("\(file) accepts \(added.count) more finding(s) than \(base.prefix(12)) (baselines only shrink)")
            }
        }

        let floorNow = try ProjectConfig.load(root: root).coverage?.minimum ?? ProjectConfig.defaultCoverageMinimum
        let floorBefore = await coverageFloor(text: baseText(ProjectConfig.fileName, base: base, git: git))
        if floorNow < floorBefore {
            let (from, to) = (Coverage.describe(minimum: floorBefore), Coverage.describe(minimum: floorNow))
            problems.append("\(ProjectConfig.fileName) lowers the coverage floor from \(from) to \(to) (it is a ratchet)")
        }

        let lintNow = (try? String(contentsOf: root.appending(path: ".swiftlint.yml"), encoding: .utf8)) ?? ""
        let lintBefore = await baseText(".swiftlint.yml", base: base, git: git) ?? ""
        for rule in yamlList("disabled_rules", in: lintNow).subtracting(yamlList("disabled_rules", in: lintBefore)).sorted() {
            problems.append(".swiftlint.yml disables the rule \(rule)")
        }
        for rule in yamlList("opt_in_rules", in: lintBefore).subtracting(yamlList("opt_in_rules", in: lintNow)).sorted() {
            problems.append(".swiftlint.yml drops the opt-in rule \(rule)")
        }
        for path in yamlList("excluded", in: lintNow).subtracting(yamlList("excluded", in: lintBefore)).sorted() {
            problems.append(".swiftlint.yml excludes \(path) from linting")
        }

        let attributesNow = (try? String(contentsOf: root.appending(path: ".gitattributes"), encoding: .utf8)) ?? ""
        let attributesBefore = Set(lines(await baseText(".gitattributes", base: base, git: git) ?? ""))
        for line in lines(attributesNow) where !attributesBefore.contains(line) {
            let hiding = line.split(whereSeparator: \.isWhitespace).dropFirst().filter { hidingAttributes.contains(String($0)) }
            if !hiding.isEmpty {
                problems.append(".gitattributes adds '\(line)', which hides changes from the review diff")
            }
        }
        return problems
    }

    private static func baseText(_ path: String, base: String, git: Git) async -> String? {
        try? await git.output(["show", "\(base):\(path)"])
    }

    private static func entries(at url: URL) throws -> Set<String> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return Set(try JSONDecoder().decode(Baseline.self, from: data).fingerprints)
        } catch {
            throw ToolError("\(url.lastPathComponent) is not a baseline: \(error)")
        }
    }

    private static func entries(inText text: String?) -> Set<String> {
        guard let data = text.map({ Data($0.utf8) }), let decoded = try? JSONDecoder().decode(Baseline.self, from: data) else { return [] }
        return Set(decoded.fingerprints)
    }

    private static func coverageFloor(text: String?) -> Double {
        guard let data = text.map({ Data($0.utf8) }), let config = try? JSONDecoder().decode(ProjectConfig.self, from: data) else {
            return ProjectConfig.defaultCoverageMinimum
        }
        return config.coverage?.minimum ?? ProjectConfig.defaultCoverageMinimum
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// The entries of a top-level YAML list (`key:` then `- item` lines, or `key: [a, b]`), comments removed.
    static func yamlList(_ key: String, in text: String) -> Set<String> {
        func clean(_ item: some StringProtocol) -> String {
            let withoutComment = item.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return withoutComment.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        }
        var items: Set<String> = []
        var inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\(key):") {
                let rest = clean(line.dropFirst(key.count + 1))
                if rest.hasPrefix("[") && rest.hasSuffix("]") {
                    items.formUnion(rest.dropFirst().dropLast().split(separator: ",").map(clean).filter { !$0.isEmpty })
                } else {
                    inside = true
                }
                continue
            }
            guard inside else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                items.insert(clean(trimmed.dropFirst(2)))
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                inside = false
            }
        }
        return items
    }

    // MARK: Base and acknowledgement

    /// `origin/main`, or its merge base with HEAD; nil without an `origin/main` (or a repository).
    static func baseRevision(git: Git) async -> String? {
        guard (try? await git.output(["rev-parse", "--verify", "--quiet", "origin/main"])) != nil else { return nil }
        return try? await git.output(["merge-base", "HEAD", "origin/main"])
    }

    /// The reason given in the environment, or in a `Policy-Ack:` trailer of any commit the branch adds to `base` (the
    /// pull request's own commits, not only HEAD, which on CI is a synthetic merge commit).
    static func acknowledgement(environment: [String: String], base: String, git: Git) async -> String? {
        if let reason = environment[acknowledgementVariable]?.trimmingCharacters(in: .whitespaces), !reason.isEmpty {
            return reason
        }
        guard let messages = try? await git.output(["log", "--format=%B", "\(base)..HEAD"]) else { return nil }
        return trailerReason(in: messages)
    }

    static func trailerReason(in messages: String) -> String? {
        for line in messages.split(whereSeparator: \.isNewline) where line.hasPrefix("\(trailerName):") {
            let reason = line.dropFirst(trailerName.count + 1).trimmingCharacters(in: .whitespaces)
            if !reason.isEmpty { return reason }
        }
        return nil
    }
}

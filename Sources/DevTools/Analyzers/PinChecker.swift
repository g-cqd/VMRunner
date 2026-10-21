import Foundation

/// Checks that the CI workflows pin the same analyzer releases as `Scripts/analyzers.lock`, so the local and CI
/// gates cannot silently diverge. A workflow carries, per tool, one `uses: g-cqd/<tool>@<commit> # v<version>` line
/// and one `version: '<version>' # <tool>` line.
enum PinChecker {
    static let workflowsDirectory = ".github/workflows"

    struct Workflow {
        let name: String
        let text: String
    }

    /// Every disagreement between the workflows and the lock; empty when they agree.
    static func problems(lock: AnalyzerLock, workflows: [Workflow]) throws -> [String] {
        var problems: [String] = []
        for tool in AnalyzerTool.allCases {
            let pin = try lock.pin(for: tool)
            let wantedUses = "g-cqd/\(tool.rawValue)@\(pin.commit) # v\(pin.version)"
            let wantedVersion = "version: '\(pin.version)' # \(tool.rawValue)"
            var usesMatched = false
            var versionMatched = false
            for workflow in workflows {
                for line in workflow.text.split(whereSeparator: \.isNewline) {
                    if let found = line.firstMatch(of: #/uses: g-cqd/(?<tool>\w+)@(?<commit>[0-9a-fA-F]+) +# v(?<version>\S+)$/#),
                        found.tool == tool.rawValue
                    {
                        if found.commit == pin.commit && found.version == pin.version {
                            usesMatched = true
                        } else {
                            problems.append("pins: \(workflow.name) does not pin \(wantedUses)")
                        }
                    }
                    if let found = line.firstMatch(of: #/version: '(?<version>[^']+)' +# (?<tool>\w+)$/#), found.tool == tool.rawValue {
                        if found.version == pin.version {
                            versionMatched = true
                        } else {
                            problems.append("pins: \(workflow.name) does not set \(wantedVersion)")
                        }
                    }
                }
            }
            if !usesMatched && !problems.contains(where: { $0.hasSuffix("pin \(wantedUses)") }) {
                problems.append("pins: \(workflowsDirectory) does not pin \(wantedUses)")
            }
            if !versionMatched && !problems.contains(where: { $0.hasSuffix("set \(wantedVersion)") }) {
                problems.append("pins: \(workflowsDirectory) does not set \(wantedVersion)")
            }
        }
        return problems
    }

    /// Reads `.github/workflows/*.yml|yaml` under `root`.
    static func loadWorkflows(root: URL) throws -> [Workflow] {
        let directory = root.appending(path: workflowsDirectory, directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .sorted()
        return try names.map { name in
            Workflow(name: "\(workflowsDirectory)/\(name)", text: try String(contentsOf: directory.appending(path: name), encoding: .utf8))
        }
    }
}

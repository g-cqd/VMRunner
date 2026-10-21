import Foundation

/// Prints the results of SARIF files as `path:line: level [rule] message`, plus a count per file.
///
/// The analyzer GitHub Actions emit SARIF only, which is unreadable in a job log; CI summarizes it with this.
enum SarifSummary {
    private struct Report: Decodable {
        struct Run: Decodable {
            struct Tool: Decodable {
                struct Driver: Decodable { let name: String? }
                let driver: Driver?
            }

            struct Result: Decodable {
                struct Message: Decodable { let text: String? }
                struct Location: Decodable {
                    struct Physical: Decodable {
                        struct Artifact: Decodable { let uri: String? }
                        struct Region: Decodable { let startLine: Int? }
                        let artifactLocation: Artifact?
                        let region: Region?
                    }
                    let physicalLocation: Physical?
                }

                let ruleId: String?
                let level: String?
                let message: Message?
                let locations: [Location]?
            }

            let tool: Tool?
            let results: [Result]?
        }

        let runs: [Run]?
    }

    /// One line per finding and one summary line per run. Never throws: the analyzer step is the gate.
    static func lines(forFileAt path: String) -> [String] {
        guard FileManager.default.fileExists(atPath: path) else {
            return ["\(path): no SARIF report (the analyzer failed before producing one)"]
        }
        let report: Report
        do {
            report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            return ["\(path): unreadable SARIF report (\(error))"]
        }
        let fallbackName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return (report.runs ?? []).flatMap { run -> [String] in
            let results = run.results ?? []
            var counts: [String: Int] = [:]
            var lines: [String] = []
            for result in results {
                let level = result.level ?? "warning"
                counts[level, default: 0] += 1
                let message = (result.message?.text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                lines.append("\(location(of: result)): \(level) [\(result.ruleId ?? "?")] \(message)")
            }
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            let name = run.tool?.driver?.name ?? fallbackName
            lines.append("\(name): \(results.count) finding(s) (\(summary.isEmpty ? "clean" : summary))")
            return lines
        }
    }

    private static func location(of result: Report.Run.Result) -> String {
        guard let physical = result.locations?.first?.physicalLocation, let uri = physical.artifactLocation?.uri else {
            return "<no location>"
        }
        let path = uri.hasPrefix("file://") ? String(uri.dropFirst("file://".count)) : uri
        return "\(path):\(physical.region?.startLine ?? 1)"
    }
}

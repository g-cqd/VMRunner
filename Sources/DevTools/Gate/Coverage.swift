import Foundation

/// The line coverage of `llvm-cov export -summary-only`.
enum Coverage {
    private struct Export: Decodable {
        struct Entry: Decodable {
            struct Totals: Decodable {
                struct Lines: Decodable { let percent: Double }
                let lines: Lines
            }
            let totals: Totals
        }
        let data: [Entry]
    }

    /// `data[0].totals.lines.percent` of the export.
    static func linePercent(fromExport data: Data) throws -> Double {
        let export: Export
        do {
            export = try JSONDecoder().decode(Export.self, from: data)
        } catch {
            throw ToolError("unreadable llvm-cov summary: \(error)")
        }
        guard let first = export.data.first else { throw ToolError("the llvm-cov summary has no data entry") }
        return first.totals.lines.percent
    }

    /// "55" for a whole number, "55.5" otherwise: the minimum as the user wrote it.
    static func describe(minimum: Double) -> String {
        minimum == minimum.rounded() && abs(minimum) < 1e15 ? String(Int(minimum)) : String(minimum)
    }

    static func line(percent: Double, minimum: Double) -> String {
        let tenths = Int((min(max(percent, 0), 100) * 10).rounded())
        return "logic-layer line coverage: \(tenths / 10).\(tenths % 10)% (minimum \(describe(minimum: minimum))%)"
    }
}

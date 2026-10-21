import Foundation
import Testing

/// The coverage gate end to end: a fixture with measurable (partial) coverage, run once per threshold.
struct CoverageTests {
    private struct Summary: Decodable {
        struct Entry: Decodable {
            struct Totals: Decodable {
                struct Lines: Decodable { let percent: Double }
                let lines: Lines
            }
            let totals: Totals
        }
        let data: [Entry]
    }

    @Test(.timeLimit(.minutes(10)))
    func theGatePassesAtTheMeasuredCoverageAndFailsJustAbove() async throws {
        try await withTemporaryDirectory { directory in
            try write(GateFixture.passing, to: directory)

            let measuring = try await VMR.vmr(["check", "coverage"], in: directory, environment: ["COVERAGE_MIN": "0"])
            #expect(measuring.status == 0, "\(measuring.combined)")
            let summary = try Data(contentsOf: directory.appending(path: ".build-cov/coverage-summary.json"))
            let percent = try #require(JSONDecoder().decode(Summary.self, from: summary).data.first).totals.lines.percent
            #expect(percent > 0 && percent < 100, "the fixture covers some lines, not all: \(percent)")
            #expect(measuring.output.contains("logic-layer line coverage: "))
            #expect(measuring.output.contains("% (minimum 0%)"))

            let atThreshold = try await VMR.vmr(["check", "coverage"], in: directory, environment: ["COVERAGE_MIN": "\(percent)"])
            #expect(atThreshold.status == 0, "a coverage equal to the minimum passes: \(atThreshold.combined)")

            let above = try await VMR.vmr(["check", "coverage"], in: directory, environment: ["COVERAGE_MIN": "\(percent + 0.1)"])
            #expect(above.status == 1)
            #expect(above.outputLines.contains { $0.hasPrefix("FAIL  coverage (") })
            #expect(above.error.contains("coverage fell below COVERAGE_MIN="), "\(above.error)")

            // The minimum can also come from .vmr.json; the environment wins over it.
            try write([".vmr.json": #"{ "coverage": { "minimum": 100 } }"#], to: directory)
            let fromFile = try await VMR.vmr(["check", "coverage"], in: directory)
            #expect(fromFile.status == 1, "\(fromFile.combined)")
            #expect(fromFile.output.contains("(minimum 100%)"))
            let overridden = try await VMR.vmr(["check", "coverage"], in: directory, environment: ["COVERAGE_MIN": "0"])
            #expect(overridden.status == 0, "\(overridden.combined)")
        }
    }

    @Test
    func aMinimumThatIsNotANumberIsRejected() async throws {
        try await withTemporaryDirectory { directory in
            try write(GateFixture.passing, to: directory)
            let run = try await VMR.vmr(["check", "coverage"], in: directory, environment: ["COVERAGE_MIN": "lots"])
            #expect(run.status == 1)
            #expect(run.error.contains("COVERAGE_MIN='lots' is not a number"), "\(run.error)")
        }
    }
}

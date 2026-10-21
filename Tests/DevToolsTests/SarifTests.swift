import Foundation
import Testing

struct SarifTests {
    private static let report = """
        {
          "runs": [{
            "tool": { "driver": { "name": "deadwood" } },
            "results": [
              {
                "ruleId": "unused-declaration",
                "level": "error",
                "message": { "text": "'helper'   is never\\n used" },
                "locations": [{ "physicalLocation": {
                  "artifactLocation": { "uri": "file:///work/Sources/A.swift" }, "region": { "startLine": 12 } } }]
              },
              { "ruleId": "dead-branch", "message": { "text": "unreachable" }, "locations": [] },
              {
                "ruleId": "unused-declaration",
                "level": "error",
                "message": { "text": "second" },
                "locations": [{ "physicalLocation": { "artifactLocation": { "uri": "Sources/B.swift" } } }]
              }
            ]
          }]
        }
        """

    @Test
    func printsEachFindingAndACountPerRun() async throws {
        try await withTemporaryDirectory { directory in
            try write(
                [
                    "deadwood.sarif": Self.report,
                    "clean.sarif": #"{ "runs": [{ "tool": { "driver": { "name": "dolly" } }, "results": [] }] }"#,
                ], to: directory)
            let run = try await VMR.vmr(["sarif", "deadwood.sarif", "clean.sarif", "missing.sarif"], in: directory)
            #expect(run.status == 0, "the SARIF summary never fails the build")
            #expect(
                run.outputLines.dropLast() == [
                    "/work/Sources/A.swift:12: error [unused-declaration] 'helper' is never used",
                    "<no location>: warning [dead-branch] unreachable",
                    "Sources/B.swift:1: error [unused-declaration] second",
                    "deadwood: 3 finding(s) (2 error, 1 warning)",
                    "dolly: 0 finding(s) (clean)",
                    "missing.sarif: no SARIF report (the analyzer failed before producing one)",
                ]
            )
        }
    }

    @Test
    func anUnreadableReportIsReportedNotFatal() async throws {
        try await withTemporaryDirectory { directory in
            try write(["broken.sarif": "{ not json"], to: directory)
            let run = try await VMR.vmr(["sarif", "broken.sarif"], in: directory)
            #expect(run.status == 0)
            #expect(run.output.contains("broken.sarif: unreadable SARIF report"))
        }
    }
}

import Foundation
import Testing

@testable import DevTools

/// `vmr check publication`: the release workflow's refusal to ship a placeholder owner or bundle identifier.
struct PublicationTests {
    private static let codeowners = """
        # Replace @OWNER with the maintainer handle when the repository is published.
        *                          @OWNER
        /.github/                  @OWNER
        """

    private static func infoPlist(identifier: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>\(identifier)</string>
        </dict>
        </plist>
        """
    }

    private func publication(codeowners: String, identifier: String) async throws -> Invocation {
        try await withTemporaryDirectory { directory in
            try write(
                [
                    "Package.swift": "// swift-tools-version: 6.0\n",
                    ".github/CODEOWNERS": codeowners,
                    "Resources/Info.plist": Self.infoPlist(identifier: identifier),
                ], to: directory)
            return try await VMR.vmr(["check", "publication"], in: directory)
        }
    }

    @Test
    func aPlaceholderOwnerFailsAndNamesItsLines() async throws {
        let run = try await publication(codeowners: Self.codeowners, identifier: "dev.acme.VMRunner")
        #expect(run.status == 1, "\(run.combined)")
        #expect(run.error.contains(".github/CODEOWNERS:2: the owner @OWNER is a placeholder that GitHub ignores"), "\(run.error)")
        #expect(run.error.contains(".github/CODEOWNERS:3:"), "every line is reported: \(run.error)")
        #expect(!run.error.contains("CODEOWNERS:1:"), "the comment that explains the placeholder is not a use of it")
        #expect(run.outputLines.contains { $0.hasPrefix("FAIL  publication (") })
    }

    @Test
    func aPlaceholderBundleIdentifierFails() async throws {
        let run = try await publication(codeowners: "* @acme/maintainers\n", identifier: "com.example.VMRunner")
        #expect(run.status == 1, "\(run.combined)")
        #expect(
            run.error.contains("Resources/Info.plist: CFBundleIdentifier com.example.VMRunner is a placeholder under com.example."),
            "\(run.error)")
        #expect(!run.error.contains("CODEOWNERS"))
    }

    @Test
    func aRepositoryWithRealOwnersAndIdentifierPasses() async throws {
        let run = try await publication(codeowners: "# owners\n* @acme/maintainers  # the team\n", identifier: "dev.acme.VMRunner")
        #expect(run.status == 0, "\(run.combined)")
        #expect(run.outputLines.contains { $0.hasPrefix("PASS  publication (") })
        #expect(run.output.contains("publication: no placeholder left"))
    }

    @Test
    func aMissingCodeownersFileFails() async throws {
        try await withTemporaryDirectory { directory in
            try write(["Resources/Info.plist": Self.infoPlist(identifier: "dev.acme.VMRunner")], to: directory)
            #expect(Publication.problems(root: directory) == [".github/CODEOWNERS: cannot read it, so no change has a review owner"])
        }
    }

    @Test
    func neitherTheFastNorTheFullGateRunsIt() {
        let names = (GateCatalog.fastSteps + GateCatalog.fullOnlySteps).map(\.name)
        #expect(!names.contains("publication"), "ordinary CI must stay green while the placeholders stand")
        #expect(GateCatalog.step(named: "publication") != nil)
    }
}

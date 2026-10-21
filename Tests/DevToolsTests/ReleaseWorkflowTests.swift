import Foundation
import Testing

/// What `release.yml` promises about integrity, read as text: there is no workflow runner in the tests.
struct ReleaseWorkflowTests {
    private static let workflows = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".github/workflows")

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: workflows.appending(path: name), encoding: .utf8)
    }

    @Test
    func thePublishJobComparesTheZipWithADigestThatDidNotTravelInTheArtifact() throws {
        let release = try Self.text("release.yml")
        #expect(release.contains("zip-sha256: ${{ steps.zip.outputs.sha256 }}"), "the build job exports the digest")
        #expect(release.contains("EXPECTED_SHA256: ${{ needs.build.outputs.zip-sha256 }}"), "the publish job reads it")
        let upload = try #require(release.range(of: "name: Upload the zip"))
        let uploaded = release[upload.upperBound...].prefix(400)
        #expect(!uploaded.contains(".sha256") && !uploaded.contains("path: dist/\n"), "the artifact holds the zip alone")
    }

    @Test
    func aReleaseNeedsCIToHavePassedOnTheTaggedCommit() throws {
        let release = try Self.text("release.yml")
        #expect(release.contains(#"gh run list --commit "$GITHUB_SHA" --workflow CI --status success"#))
        #expect(release.contains("actions: read"))
    }

    @Test
    func theAttestationIsGatedOnAContextPropertyThatExists() throws {
        let release = try Self.text("release.yml")
        #expect(!release.contains("github.repository_visibility"), "that property is not part of the github context")
        #expect(release.contains("if: ${{ github.event.repository.private == false }}"), "the attestation is for public repositories")
        #expect(release.contains("if: ${{ github.event.repository.private != false }}"), "and the skip is announced")
    }
}

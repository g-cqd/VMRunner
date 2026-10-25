import Foundation
import Testing

@testable import VMRunner

/// The build away from the main actor must end as the build it wraps does, whichever way that is.
@MainActor
struct ConfigurationBuildTests {
    @Test func theBuildAwayFromTheMainActorEndsLikeTheBuild() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = VMBundle(url: directory)
        try Data(count: 1 << 20).write(to: bundle.disk)
        try writeEFIVariableStore(at: bundle.efiVariables)
        let config = VMConfig.new(name: "x", guest: .linux)

        let direct: String
        do {
            _ = try ConfigurationBuilder.build(config, bundle: bundle)
            direct = "built"
        } catch { direct = "\(error)" }
        let detached: String
        do {
            _ = try await ConfigurationBuilder.buildInBackground(config, bundle: bundle)
            detached = "built"
        } catch {
            detached = "\(error)"
        }
        #expect(detached == direct)
    }
}

import Observation
import Virtualization

/// Rosetta availability for the Sharing section.
@MainActor @Observable
final class SharingModel {
    private(set) var rosetta = VZLinuxRosettaDirectoryShare.availability
    private(set) var rosettaError: String?

    func installRosetta() async {
        do {
            try await VZLinuxRosettaDirectoryShare.installRosetta()
            rosettaError = nil
        } catch {
            rosettaError = error.localizedDescription
        }
        rosetta = VZLinuxRosettaDirectoryShare.availability
    }
}

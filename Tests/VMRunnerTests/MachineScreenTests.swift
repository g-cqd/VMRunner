import Testing

@testable import VMRunner

/// What the running machine's window is told to show.
@MainActor
struct MachineScreenTests {
    @Test
    func aMachineOnTheCustomGPUShowsItsScreenWhileItRuns() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        let guest = rig.factory.add()
        let source = FakeCustomSource()
        guest.customDisplay = source
        let model = rig.library.model(for: rig.id)
        #expect(model.customDisplay == nil, "a stopped machine has no screen of its own")

        await rig.start()
        #expect(model.customDisplay === source, "a machine on the custom GPU shows its screen")

        guest.powerOff()
        rig.expectReleased()
        #expect(model.customDisplay == nil, "a stopped machine shows its settings again")
    }

    @Test
    func aMachineWithoutACustomGPUHasNoneEvenWhileItRuns() async throws {
        let rig = try ControllerRig()
        defer { rig.cleanUp() }
        rig.factory.add()
        await rig.start()
        #expect(rig.library.model(for: rig.id).customDisplay == nil)
    }
}

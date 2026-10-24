import Testing

@testable import VirtioGPURunnerCore

struct GPUWireTests {
    @Test
    func theIdentityIsAVirtioGPUOnADisplayClass() {
        #expect(GPUWire.deviceID == 16)
        #expect(GPUWire.pciClassID == 0x03)
        #expect(GPUWire.pciSubclassID == 0x80)
        #expect(GPUWire.queueCount == 2)
        #expect([GPUWire.controlQueue, GPUWire.cursorQueue] == [0, 1])
        #expect(GPUWire.versionOneFeatureSubset1 == 1, "VIRTIO_F_VERSION_1 is bit 32, bit 0 of the upper half")
        #expect(GPUWire.eventDisplay == 1)
    }

    @Test
    func theConfigurationSpaceIsSixteenLittleEndianBytes() {
        let space = GPUConfigSpace(eventsRead: 0x0403_0201, eventsClear: 0, scanoutCount: 1, capsetCount: 0x8000_0000)
        #expect(space.bytes.count == 16)
        #expect(space.bytes == [1, 2, 3, 4, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x80])
    }

    @Test
    func oneScanoutAndNoCapabilitySets() {
        let space = GPUConfigSpace(eventsRead: 0, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
        #expect(space.bytes == [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    }
}

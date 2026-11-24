import Foundation
import VirtioGPU
import Virtualization
import os

/// The bounded RAM framebuffer display. The framework's visible view, not this device, carries the owner's USB input.
@available(macOS 27.0, *)
@MainActor
final class WindowsDisplaySession: NSObject, CustomDisplaySource,
    @preconcurrency VZCustomVirtioDeviceConfigurationDelegate, @preconcurrency VZCustomVirtioDeviceDelegate
{
    let screen = CustomScreen(displaySize: CGSize(width: 1920, height: 1200))
    let input: any GuestInputSurface = FrameworkInputSurface()
    nonisolated var prefersFrameworkOverlay: Bool { true }
    private let variables: URL
    private let token: Data
    private let sleep: (Duration) async throws -> Void
    private let now: () -> Duration
    private var device: VZCustomVirtioDevice?
    private var task: Task<Void, Never>?
    private var previous: Data?
    private var record: WindowsFrameRecord?

    init<C: Clock>(variables: URL, token: Data, clock: C) where C.Duration == Duration {
        self.variables = variables
        self.token = token
        let start = clock.now
        now = { start.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }

    convenience init(variables: URL, token: Data) {
        self.init(variables: variables, token: token, clock: ContinuousClock())
    }

    isolated deinit { task?.cancel() }

    func requestDisplaySize(width: UInt32, height: UInt32) -> Bool { false }

    nonisolated func makeConfiguration() -> VZCustomVirtioDeviceConfiguration {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = 0x7f
        configuration.pciClassID = 0xff
        configuration.pciSubclassID = 0
        configuration.virtioQueueCount = 1
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: .main, delegate: self)
        configuration.supportsSaveRestore = false
        return configuration
    }

    nonisolated func makeInputConfigurations() -> [VZCustomVirtioDeviceConfiguration] { [] }

    // The provider explicitly selects the main queue, as required by these MainActor callbacks.
    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        self.device = device
        device.delegate = self
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        // No guest queues are supported; never interpret an accidental queue as another device's protocol.
        device.requestReset()
    }

    func beginDisplay(for machine: VZVirtualMachine, failure: @escaping @MainActor (String) -> Void) {
        endDisplay()
        task = Task { [weak self, weak machine, now, sleep] in
            let start = now()
            var timing = WindowsDisplayTiming()
            while !Task.isCancelled, let machine {
                if machine.state == .running {
                    let elapsed = now() - start
                    if timing.needsMetadata(at: elapsed) {
                        self?.readRecord()
                        timing.readMetadata(at: elapsed)
                    }
                    if let status = self?.record?.status, status != 0 {
                        try? await machine.stop()
                        failure(
                            "Windows framebuffer bootstrap failed (EFI status 0x\(String(status, radix: 16))). "
                                + "Check the ARM64 installer and boot media."
                        )
                        return
                    }
                    if self?.drawFrame() == true { timing.mappedFrame(at: elapsed) }
                    if timing.timedOut(at: elapsed) {
                        try? await machine.stop()
                        failure(
                            "Windows provided no readable framebuffer for 60 seconds. The guest was stopped; no stock boot was attempted.")
                        return
                    }
                }
                do { try await sleep(.milliseconds(67)) } catch { return }
            }
        }
    }

    func endDisplay() {
        task?.cancel()
        task = nil
        previous = nil
        record = nil
        screen.clear()
    }

    private func readRecord() {
        let previousGeneration = record?.generation
        record = nil
        do {
            let handle = try FileHandle(forReadingFrom: variables)
            defer { try? handle.close() }
            if let data = try handle.read(upToCount: WindowsFrameRecord.maximumStoreBytes + 1) {
                record = WindowsFrameRecord.decode(data, token: token)
                if let generation = record?.generation, generation != previousGeneration {
                    previous = nil
                    screen.clear()
                    Log.display.notice("Windows framebuffer metadata verified, generation \(generation), fixed 1920x1200")
                }
            }
        } catch { return }
    }

    private func drawFrame() -> Bool {
        guard let device, let record, record.status == 0,
            let mapping = device.guestMemoryMapping(atPhysicalAddress: record.address, length: record.byteCount),
            mapping.length >= record.byteCount
        else { return false }
        // The public framework mapping validates the guest physical range. Copy only the checked frame while it is alive;
        // never retain its pointer or mapping across a tick, reboot or stop, and never write guest memory.
        let pixels = unsafe Data(bytes: mapping.mutableBytes, count: record.byteCount)
        guard pixels != previous else { return true }
        // Leave Apple's firmware view visible until the guest draws: the media's real boot-key prompt must remain visible.
        if previous == nil, !pixels.contains(where: { $0 != 0 }) {
            previous = pixels
            return true
        }
        if screen.frame == nil { Log.display.notice("Windows guest RAM display is drawing; no image files saved") }
        previous = pixels
        screen.show(ScanoutUpdate(width: UInt32(record.width), height: UInt32(record.height), format: .b8g8r8x8, pixels: Array(pixels)))
        return true
    }
}

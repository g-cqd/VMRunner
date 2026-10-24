import Foundation
import VirtioGPURunnerCore
import Virtualization

/// The host side of the virtio GPU device. The framework calls it on the device queue, which is the main queue, so its
/// state is main-actor state. Each request is copied out of guest memory once, decoded and carried out by
/// `GPUDeviceState`, answered when the guest left room for the answer, and given back exactly once. Every request goes to
/// the bounded command record; only milestones are printed.
@available(macOS 27.0, *)
@MainActor
final class GPUDevice: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate {
    private let started = ContinuousClock.now
    private let probeConfigChangeSeconds: Int?
    private var device: VZCustomVirtioDevice?
    private var state = GPUDeviceState()
    private var recorder = CommandRecorder()
    private var notifications = 0
    private var oversized = 0
    private var unanswered = 0
    private var flushes = 0
    private var failures = 0
    private var probeArmed = false
    /// Where each new picture of the scanout goes (the window, the PNG file); none in a run without either.
    var sinks: [any ScanoutSink] = []

    init(probeConfigChangeSeconds: Int?) {
        self.probeConfigChangeSeconds = probeConfigChangeSeconds
    }

    /// Milliseconds since the device object was made: the clock of the log, the record and the pictures.
    var milliseconds: UInt64 {
        let elapsed = ContinuousClock.now - started
        return UInt64(elapsed.components.seconds) * 1000 + UInt64(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// One line, prefixed with the seconds since the device object was made.
    func log(_ text: String) {
        let now = milliseconds
        Output.line("[\(now / 1000).\(String(now % 1000 + 1000).dropFirst())] \(text)")
    }

    /// The text of `commands.log`.
    func report() -> String {
        recorder.report(extra: [
            "queue notifications: \(notifications)", "oversized requests refused: \(oversized)",
            "answers that did not fit the guest's buffer: \(unanswered)", "scanout flushes: \(flushes)",
            "failed reads and writes of a request or an answer: \(failures)",
        ])
    }

    func customVirtioConfiguration(
        _ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice
    ) {
        device.delegate = self
        self.device = device
        log("device created")
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        let features = device.negotiatedFeatures
        log("DRIVER_OK, negotiated features subset0 \(features?.subset0 ?? 0) subset1 \(features?.subset1 ?? 0)")
        if let seconds = probeConfigChangeSeconds, !probeArmed {
            probeArmed = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                await self.signalDisplayChange()
            }
        }
    }

    /// Sets the display event in the configuration space, as a host does when the display changed. A guest that is told of
    /// the change asks for the display information again; the record shows whether and when it did.
    private func signalDisplayChange() async {
        guard let device else { return }
        let space = GPUConfigSpace(eventsRead: GPUWire.eventDisplay, eventsClear: 0, scanoutCount: 1, capsetCount: 0)
        recorder.noteConfigurationUpdate(atMilliseconds: milliseconds)
        log("configuration update: display event set")
        do {
            try await device.update(VZVirtioDeviceSpecificConfiguration(configurationData: Data(space.bytes)))
            log("configuration update completed")
        } catch {
            log("configuration update failed: \(error.localizedDescription)")
        }
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        notifications += 1
        let kind: GPUQueueKind = queue.queueIndex == GPUWire.cursorQueue ? .cursor : .control
        let memory = MappedGuestMemory(device: device)
        while let element = queue.nextElement() {
            service(element, on: kind, memory: memory)
        }
    }

    /// Reads the request once, handles the copy, writes the answer when it fits, and gives the element back exactly once.
    private func service(_ element: VZVirtioQueueElement, on queue: GPUQueueKind, memory: MappedGuestMemory) {
        defer { element.returnToQueue() }
        let length = element.readBuffersAvailableByteCount
        guard length <= state.store.limits.maxCommandBytes else {
            refuse(element, length: length, on: queue)
            return
        }
        let bytes: [UInt8]
        do {
            bytes = length == 0 ? [] : [UInt8](try element.readBytes(withExactLength: length))
        } catch {
            noteFailure("could not read a request of \(length) bytes: \(error.localizedDescription)")
            return
        }
        let handled = state.handle(bytes, queue: queue, memory: memory)
        for line in recorder.record(handled.logEntry, atMilliseconds: milliseconds) {
            log(line)
        }
        if let update = handled.scanoutUpdate {
            flushes += 1
            if flushes == 1 { log("first scanout flush: \(update.width) x \(update.height), format \(update.format)") }
            for sink in sinks { sink.show(update, atMilliseconds: milliseconds) }
        }
        if let response = handled.response { answer(element, with: response) }
    }

    /// A request longer than the device reads: only its header is read, and it is answered as an invalid parameter.
    private func refuse(_ element: VZVirtioQueueElement, length: Int, on queue: GPUQueueKind) {
        oversized += 1
        if oversized == 1 { log("refused a request of \(length) bytes, more than the device reads") }
        let header = (try? element.readBytes(withExactLength: GPUWireSize.header)).map { [UInt8]($0) } ?? []
        guard queue == .control else { return }
        let request = GPUDecoder.decode(header, limits: state.store.limits)
        answer(element, with: GPUResponse.error(.errInvalidParameter).encoded(answering: request.header))
    }

    private func answer(_ element: VZVirtioQueueElement, with response: [UInt8]) {
        guard element.writeBuffersAvailableByteCount >= response.count else {
            unanswered += 1
            if unanswered == 1 { log("an answer of \(response.count) bytes did not fit the guest's buffer; nothing was written") }
            return
        }
        do {
            try element.write(Data(response))
        } catch {
            noteFailure("could not write an answer: \(error.localizedDescription)")
        }
    }

    /// Counts a failed read or write and prints only the first, so a guest cannot make the log grow.
    private func noteFailure(_ text: String) {
        failures += 1
        if failures == 1 { log(text) }
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) { log("device stopping") }
    func customVirtioDeviceWillPause(_ device: VZCustomVirtioDevice) { log("device pausing") }
    func customVirtioDeviceWillResume(_ device: VZCustomVirtioDevice) { log("device resuming") }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        state.reset()
        log("device reset: resources and scanout forgotten")
    }
}

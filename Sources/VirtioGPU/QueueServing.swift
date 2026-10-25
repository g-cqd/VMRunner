/// One element of a virtio queue as the device sees it: the bytes the guest wrote for the device, the room it left for the
/// answer, and the one way back to the guest. An adapter conforms its framework's element to this protocol, so the rules of
/// serving an element are written once, here, and tested without a machine.
package protocol QueueElement {
    /// The bytes the guest wrote for the device, all buffers together.
    var readableByteCount: Int { get }
    /// The room the guest left for the answer, all buffers together.
    var writableByteCount: Int { get }
    /// Copies the first `count` readable bytes, exactly `count` of them or an error. `serve` reads an element at most once,
    /// because the guest may change its memory between two reads.
    func read(count: Int) throws -> [UInt8]
    /// Writes the answer into the writable buffers. `serve` calls it only when the answer fits `writableByteCount`.
    func write(_ bytes: [UInt8]) throws
    /// Gives the element back to the guest, which is told that it is used. `serve` calls it exactly once.
    func giveBack()
}

/// What became of the answer to one served element.
package enum AnswerStatus {
    case written
    /// The request has no answer: it came on the cursor queue.
    case notNeeded
    /// The guest left less room than the answer needs, so nothing was written.
    case didNotFit(needed: Int, available: Int)
    case failed(any Error)
}

/// What serving one element did, for the adapter's counters and log.
package enum ServeOutcome {
    /// The request was read and carried out.
    case handled(answer: AnswerStatus)
    /// The request was longer than the device reads. Only its header was read; `answer` is the refusal's.
    case oversized(length: Int, answer: AnswerStatus)
    /// The request could not be read.
    case unreadable(length: Int, error: any Error)
}

extension GPUDeviceState {
    /// Serves one queue element, whatever it holds. The request is read once, in one piece, and a request longer than
    /// `GPULimits.maxCommandBytes` only as far as its header, which is answered as an invalid parameter on the control queue.
    /// `whenHandled` sees the carried-out command before its answer is written. The answer is written only when it fits the
    /// room the guest left. The element is given back exactly once on every path, after anything was written.
    package mutating func serve(
        _ element: some QueueElement, on queue: GPUQueueKind, memory: some GuestMemoryReader,
        whenHandled: (HandledCommand) -> Void = { _ in }
    ) -> ServeOutcome {
        defer { element.giveBack() }
        let length = element.readableByteCount
        guard length <= store.limits.maxCommandBytes else {
            return .oversized(length: length, answer: refuse(element, on: queue))
        }
        let bytes: [UInt8]
        do {
            bytes = length == 0 ? [] : try element.read(count: length)
        } catch {
            return .unreadable(length: length, error: error)
        }
        let handled = handle(bytes, queue: queue, memory: memory)
        whenHandled(handled)
        guard let response = handled.response else { return .handled(answer: .notNeeded) }
        return .handled(answer: Self.write(response, to: element))
    }

    /// Reads only the header of an element that is too long, and answers it on the control queue.
    private func refuse(_ element: some QueueElement, on queue: GPUQueueKind) -> AnswerStatus {
        let header = (try? element.read(count: GPUWireSize.header)) ?? []
        guard queue == .control else { return .notNeeded }
        let request = GPUDecoder.decode(header, limits: store.limits)
        return Self.write(GPUResponse.error(.errInvalidParameter).encoded(answering: request.header), to: element)
    }

    private static func write(_ response: [UInt8], to element: some QueueElement) -> AnswerStatus {
        let available = element.writableByteCount
        guard available >= response.count else { return .didNotFit(needed: response.count, available: available) }
        do {
            try element.write(response)
            return .written
        } catch {
            return .failed(error)
        }
    }
}

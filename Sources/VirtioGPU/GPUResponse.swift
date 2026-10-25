/// One mode of a display-information answer.
package struct GPUDisplayMode: Equatable, Sendable {
    package var rect: GPURect
    package var enabled: Bool

    package init(rect: GPURect, enabled: Bool) {
        self.rect = rect
        self.enabled = enabled
    }
}

/// An answer the device writes back into the request's write buffers.
package enum GPUResponse: Equatable, Sendable {
    case noData
    /// Up to 16 modes; the answer always carries 16, the missing ones zeroed and disabled.
    case displayInfo([GPUDisplayMode])
    case error(GPUResponseType)

    private static let disabledMode = GPUDisplayMode(rect: GPURect(x: 0, y: 0, width: 0, height: 0), enabled: false)

    package var type: GPUResponseType {
        switch self {
        case .noData: .okNoData
        case .displayInfo: .okDisplayInfo
        case .error(let type): type
        }
    }

    /// The bytes of the answer to a request with `request`'s header. The fence flag, the fence id and the context are echoed
    /// when the request asked for a fence, and the ring index when it named one. The device handles a request completely
    /// before it answers, so an answer that carries a fence is written only once the request's effect is done.
    package func encoded(answering request: GPUControlHeader) -> [UInt8] {
        let fenced = request.flags & GPUControlHeader.fenceFlag != 0
        let flags = request.flags & (GPUControlHeader.fenceFlag | GPUControlHeader.ringIndexFlag)
        var writer = ByteWriter(capacity: GPUWireSize.displayInfo)
        writer.u32(type.rawValue)
        writer.u32(flags)
        writer.u64(fenced ? request.fenceID : 0)
        writer.u32(fenced ? request.contextID : 0)
        writer.u8(flags & GPUControlHeader.ringIndexFlag != 0 ? request.ringIndex : 0)
        writer.zeros(3)
        if case .displayInfo(let modes) = self {
            for index in 0..<GPUWireSize.displayModes {
                let mode = index < modes.count ? modes[index] : Self.disabledMode
                writer.u32(mode.rect.x)
                writer.u32(mode.rect.y)
                writer.u32(mode.rect.width)
                writer.u32(mode.rect.height)
                writer.u32(mode.enabled ? 1 : 0)
                writer.u32(0)
            }
        }
        return writer.bytes
    }
}

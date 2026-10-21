import Foundation
import Testing

@testable import VMRunner

/// Single-stream TCP throughput through the whole stack over loopback: a fast scripted guest, the real loop thread,
/// real sockets, a real loopback server. Debug builds are slow, so the floor asserted here is low; the numbers worth
/// quoting come from a release build (`swift test -c release -Xswiftc -enable-testing --filter UserNetThroughput`)
/// and are written to standard error when `USERNET_BENCH` is set.
extension UserNetIntegration {
    struct UserNetThroughputTests {
        #if DEBUG
            private static let defaultMegabytes = 8
        #else
            private static let defaultMegabytes = 256
        #endif

        /// `USERNET_BENCH_MIB` overrides the transfer size.
        private static let megabytes = ProcessInfo.processInfo.environment["USERNET_BENCH_MIB"].flatMap { Int($0) } ?? defaultMegabytes

        private func report(_ label: String, bytes: Int, seconds: Double) -> Double {
            let rate = Double(bytes) / 1_048_576 / seconds
            if ProcessInfo.processInfo.environment["USERNET_BENCH"] != nil {
                let megabytes = bytes / 1_048_576
                let line =
                    "BENCH \(label): \(megabytes) MiB in \((seconds * 1_000).rounded() / 1_000) s = \((rate * 10).rounded() / 10) MiB/s\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            return rate
        }

        /// Sends `total` bytes as fast as the stack's window allows, reading ACKs between bursts.
        private func upload(_ guest: GuestHarness, _ socket: GuestTCP, total: Int, segment: Int, diagnostics: () -> String = { "" })
            -> Double
        {
            let frames = (total + segment - 1) / segment
            let template = pattern(segment)
            let packets: [[UInt8]] = (0..<frames).map { index in
                let size = min(segment, total - index * segment)
                return Wire.guestFrame(
                    Wire.ipv4(
                        from: Wire.guest, to: socket.remote.address, proto: IPProtocol.tcp,
                        Wire.tcp(
                            from: (Wire.guest, socket.localPort), to: socket.remote, sequence: socket.sequence &+ UInt32(index * segment),
                            acknowledgement: socket.expected, flags: .pushAck, window: 65_535, payload: Array(template.prefix(size)))))
            }
            let start = ContinuousClock.now
            let deadline = Date.now.addingTimeInterval(30)
            var sent = 0
            let base = socket.sequence
            let end = base &+ UInt32(total)
            var acknowledged = base
            // Non-blocking reads straight off the socket, and bursts of sends, so the scripted guest costs as little as possible.
            _ = SocketCalls.setNonBlocking(guest.link.descriptor)
            let buffer = RawBuffer(capacity: 65_600)
            while acknowledged != end, Date.now < deadline {
                var burst = 0
                while burst < 32, sent < frames {
                    let inFlight = TCPSequence.distance(from: acknowledged, to: base &+ UInt32(min(sent * segment, total)))
                    guard inFlight + segment <= socket.peerWindow else { break }
                    guest.link.send(packets[sent])
                    sent += 1
                    burst += 1
                }
                var drained = false
                while case .transferred(let count) = SocketCalls.receive(guest.link.descriptor, into: buffer.mutableView) {
                    drained = true
                    let frame = buffer.view(length: count)
                    guard count >= 54, let ack = try? frame.be32(at: 14 + 20 + 8), let window = try? frame.be16(at: 14 + 20 + 14),
                        TCPSequence.lessOrEqual(acknowledged, ack)
                    else { continue }
                    acknowledged = ack
                    socket.peerWindow = Int(window) << socket.peerShift  // pure window updates repeat the old ACK number
                }
                if !drained, burst == 0 { _ = guest.link.waitUntilReadable(timeout: 0.05) }
            }
            if acknowledged != end {
                Issue.record(
                    "upload stalled: sent \(sent)/\(frames) frames, acknowledged \(acknowledged &- base)/\(total), \(diagnostics())")
            }
            socket.sequence = end
            socket.unacknowledged = acknowledged
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        }

        @Test(arguments: [1_500, 9_000])
        func uploadThroughput(mtu: Int) async throws {
            let server = try #require(LoopbackServer(.sink))
            defer { server.close() }
            let total = Self.megabytes * 1_048_576
            var config = UserNetConfig.loopbackReachable
            config.mtu = mtu
            try await withNetwork(config: config) { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (ipv4("127.0.0.1"), server.port), mss: mtu - 40))
                let seconds = upload(
                    guest, socket, total: total, segment: socket.mss,
                    diagnostics: { "server has \(server.receivedBytes.count) \(network.stack.stats)" })
                guest.shutdownWrite(socket)
                #expect(guest.receiveToEnd(socket, timeout: 30) == Array("received \(total)".utf8))
                let stats = network.stack.stats
                let label = "upload mtu \(mtu) retransmits \(stats.tcpRetransmits) lost \(stats.framesLostToGuest)"
                let rate = report(label, bytes: total, seconds: seconds)
                #expect(rate > 2, "upload ran at \(rate) MiB/s")
            }
        }

        @Test(arguments: [1_500, 9_000])
        func downloadThroughput(mtu: Int) async throws {
            let total = Self.megabytes * 1_048_576
            let server = try #require(LoopbackServer(.bulk(pattern(total))))
            defer { server.close() }
            var config = UserNetConfig.loopbackReachable
            config.mtu = mtu
            try await withNetwork(config: config) { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (ipv4("127.0.0.1"), server.port), mss: mtu - 40))
                let start = ContinuousClock.now
                var received = 0
                var pendingAcks = 0
                while received < total {
                    guard let raw = guest.link.receive(timeout: 2) else { break }
                    let view = raw
                    guard view.count > 54, view[23] == IPProtocol.tcp else { continue }
                    let payload = view.count - 54
                    received += payload
                    socket.expected &+= UInt32(payload)
                    pendingAcks += 1
                    if pendingAcks >= 2 {
                        pendingAcks = 0
                        guest.sendSegment(socket, .ack)
                    }
                }
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
                #expect(received == total)
                let rate = report(
                    "download mtu \(mtu) retransmits \(network.stack.stats.tcpRetransmits) frames \(network.stack.stats.framesToGuest)",
                    bytes: total, seconds: seconds)
                #expect(rate > 2, "download ran at \(rate) MiB/s")
            }
        }
    }
}

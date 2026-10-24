import Foundation
import NetPolicy
import Testing

@testable import NetStack

private let loopback = ipv4("127.0.0.1")

private func policy(_ configure: (inout NetworkPolicy) throws -> Void) rethrows -> NetworkPolicy {
    var value = CoreRig.openPolicy
    try configure(&value)
    return value
}

/// Whether this host really answers a loopback echo through an unprivileged ICMP socket. Creating the socket is not
/// enough: a sandbox may forbid it, and the Application Firewall's stealth mode (seen on macOS 27) drops echo requests
/// addressed to local addresses. So the gate sends one echo request to 127.0.0.1 and waits up to 1 second for a reply.
private let icmpSocketsWork: Bool = {
    guard let descriptor = SocketCalls.makeSocket(type: SOCK_DGRAM, protocolNumber: Int32(IPPROTO_ICMP)) else { return false }
    defer { SocketCalls.close(descriptor) }
    guard SocketCalls.connect(descriptor, address: loopback, port: 0) == 0 else { return false }
    // Type 8 (echo request), code 0, checksum 0xE5CA (0xFFFF - 0x0800 - 0x1234 - 0x0001), identifier 0x1234, sequence 1.
    let request: [UInt8] = [8, 0, 0xE5, 0xCA, 0x12, 0x34, 0, 1]
    let sent = request.withUnsafeBytes { unsafe send(descriptor, $0.baseAddress, $0.count, 0) }
    guard sent == request.count else { return false }
    var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return unsafe poll(&entry, 1, 1_000) == 1 && entry.revents & Int16(POLLIN) != 0
}()

extension UserNetIntegration {
    struct UserNetBootTests {
        @Test func aGuestBootsWithDHCPAndARP() async throws {
            try await withNetwork { network in
                #expect(network.guest.address == Wire.guest)
                #expect(network.stack.stats.dhcpAcks == 1)
            }
        }

        @Test func theGatewayAnswersPing() async throws {
            try await withNetwork { network in
                network.guest.ping(Wire.gateway, identifier: 9)
                let reply = try #require(network.guest.receivePingReply())
                #expect(reply.icmpType == 0 && reply.ipSource == Wire.gateway && reply.transportChecksumValid)
            }
        }

        @Test func dnsGoesThroughTheInjectedResolverNotTheInternet() async throws {
            let resolver = StubResolver(table: ["app.test": ["10.1.2.3"]], canonical: [:])
            try await withNetwork(resolver: resolver) { network in
                let found = try network.guest.mustResolve("app.test")
                #expect(found.code == 0 && found.addresses == [ipv4("10.1.2.3")])
                try #expect(network.guest.mustResolve("missing.test").code == 3)
                let ipv6 = try network.guest.mustResolve("app.test", type: 28)
                #expect(ipv6.code == 0 && ipv6.addresses.isEmpty)
                try #expect(network.guest.mustResolve("app.test", server: ipv4("8.8.8.8")).addresses == [ipv4("10.1.2.3")])
                // Events are delivered in order, so seeing the last query's event means all four are in the log.
                _ = await network.events.next { $0.destinationAddress == .v4(ipv4("8.8.8.8")) }
                #expect(network.events.count { if case .answered = $0.phase { true } else { false } } == 4)
            }
        }

        @Test func dnsOverTCPWorksThroughTheStack() async throws {
            let resolver = StubResolver(table: ["app.test": ["10.1.2.3"]], canonical: [:])
            try await withNetwork(resolver: resolver) { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (Wire.gateway, 53)))
                let query = Wire.dnsQuery(id: 5, name: "app.test")
                guest.send(socket, Wire.be16(query.count) + query)
                let length = guest.receive(socket, count: 2)
                let message = guest.receive(socket, count: Int(length[0]) << 8 | Int(length[1]))
                #expect(Array(message.suffix(4)) == Wire.be32(ipv4("10.1.2.3")))
                guest.shutdownWrite(socket)
                #expect(guest.receiveToEnd(socket).isEmpty)
                #expect(socket.finReceived)
            }
        }
    }
}

extension UserNetIntegration {
    struct UserNetTCPThroughStackTests {
        @Test func smallEchoThroughTheStack() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                guest.send(socket, Array("hello through the stack".utf8))
                #expect(guest.receive(socket, count: 23) == Array("hello through the stack".utf8))
                guest.shutdownWrite(socket)
                #expect(guest.receiveToEnd(socket).isEmpty)
                let opened = try #require(await network.events.next { $0.phase == .opened })
                #expect(opened.destinationPort == server.port && opened.transport == .tcp)
                let closed = try #require(await network.events.next { $0.phase == .closed(.finished) })
                #expect(closed.bytesToHost == 23 && closed.bytesToGuest == 23 && closed.duration >= 0)
                #expect(server.connectionCount == 1)
            }
        }

        @Test func aMultiMegabyteEchoArrivesIntactInBothDirections() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                let payload = pattern(4 * 1_024 * 1_024, seed: 3)
                #expect(guest.send(socket, payload))
                guest.shutdownWrite(socket)
                let echoed = guest.receiveToEnd(socket, timeout: 30)
                #expect(echoed.count == payload.count)
                #expect(echoed == payload)
                #expect(network.stack.stats.tcpRetransmits == 0, "a healthy loopback transfer needs no retransmission")
            }
        }

        @Test func downloadsWhereTheServerClosesFirstDeliverEverythingBeforeTheFIN() async throws {
            let server = try #require(LoopbackServer(.bulk(pattern(3_000_000))))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                let downloaded = guest.receiveToEnd(socket, timeout: 30)
                #expect(downloaded == pattern(3_000_000))
                #expect(socket.finReceived && !socket.reset)
                guest.shutdownWrite(socket)
                #expect(await network.events.next { $0.phase == .closed(.finished) } != nil)
            }
        }

        @Test func uploadsAreDeliveredCompletelyToTheServer() async throws {
            let server = try #require(LoopbackServer(.sink))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                let payload = pattern(2 * 1_024 * 1_024, seed: 11)
                #expect(guest.send(socket, payload))
                guest.shutdownWrite(socket)
                #expect(guest.receiveToEnd(socket, timeout: 30) == Array("received \(payload.count)".utf8))
                #expect(server.receivedBytes == payload)
            }
        }

        @Test func halfCloseLetsTheServerAnswerAfterTheGuestIsDone() async throws {
            let server = try #require(LoopbackServer(.replyAfterEOF(Array("final answer".utf8))))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                guest.send(socket, Array("request".utf8))
                guest.shutdownWrite(socket)
                #expect(guest.receiveToEnd(socket) == Array("final answer".utf8))
            }
        }

        @Test func aServerThatClosesImmediatelyStillDeliversItsGreeting() async throws {
            let server = try #require(LoopbackServer(.greeting(Array("220 hello".utf8))))
            defer { server.close() }
            try await withNetwork { network in
                let socket = try #require(network.guest.connect(to: (loopback, server.port)))
                #expect(network.guest.receiveToEnd(socket) == Array("220 hello".utf8))
                #expect(socket.finReceived)
            }
        }

        @Test func aServerThatResetsBecomesAResetForTheGuest() async throws {
            let server = try #require(LoopbackServer(.reset))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                guest.pump(timeout: 5) { socket.reset }
                #expect(socket.reset)
                let closed = try #require(await network.events.next { if case .closed(.hostError) = $0.phase { true } else { false } })
                #expect(closed.destinationPort == server.port)
            }
        }

        @Test func aClosedPortIsRefusedAndReported() async throws {
            let unused = try #require(TestSockets.bindLoopback(type: SOCK_STREAM))
            close(unused.descriptor)
            try await withNetwork { network in
                #expect(network.guest.connect(to: (loopback, unused.port)) == nil, "the guest sees the refusal as a reset")
                let failed = await network.events.next { $0.phase == .closed(.connectFailed(ECONNREFUSED)) }
                #expect(failed?.destinationPort == unused.port)
            }
        }

        @Test func manyConcurrentConnectionsAreIndependent() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let sockets = try (0..<12).map { _ in try #require(guest.connect(to: (loopback, server.port))) }
                for (index, socket) in sockets.enumerated() { guest.send(socket, pattern(5_000, seed: index)) }
                for (index, socket) in sockets.enumerated() { #expect(guest.receive(socket, count: 5_000) == pattern(5_000, seed: index)) }
                #expect(network.stack.stats.activeTCPFlows == 12)
            }
        }
    }
}

extension UserNetIntegration {
    struct UserNetUDPThroughStackTests {
        @Test func udpEchoThroughTheStack() async throws {
            let server = try #require(LoopbackUDPServer())
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                guest.sendUDP(to: (loopback, server.port), from: 40_123, Array("datagram".utf8))
                let echoed = try #require(guest.receiveUDP(on: 40_123))
                #expect(echoed.payload == Array("datagram".utf8))
                #expect(echoed.ipSource == loopback && echoed.sourcePort == server.port)
                #expect(server.datagramCount == 1)
                #expect(await network.events.next { $0.transport == .udp && $0.phase == .opened } != nil)
            }
        }

        @Test func aFullSizeDatagramRoundTrips() async throws {
            let server = try #require(LoopbackUDPServer())
            defer { server.close() }
            try await withNetwork { network in
                let payload = pattern(1_472)  // the largest UDP payload that fits a 1500-byte MTU
                network.guest.sendUDP(to: (loopback, server.port), from: 40_124, payload)
                let echoed = try #require(network.guest.receiveUDP(on: 40_124))
                #expect(echoed.payload == payload)
            }
        }

        @Test(.enabled(if: icmpSocketsWork, "needs a host that answers loopback ICMP echo (not a sandbox, not Firewall stealth mode)"))
        func pingToLoopbackThroughTheStack() async throws {
            try await withNetwork { network in
                network.guest.ping(loopback, identifier: 0x3344, sequence: 7)
                let reply = try #require(network.guest.receivePingReply(timeout: 5))
                #expect(reply.icmpType == 0 && reply.transportChecksumValid && reply.ipSource == loopback)
                #expect(reply.payload.count >= 8 && reply.payload[4] == 0x33 && reply.payload[5] == 0x44 && reply.payload[7] == 7)
            }
        }

        @Test(.enabled(if: icmpSocketsWork, "needs a host that answers loopback ICMP echo (not a sandbox, not Firewall stealth mode)"))
        func aDeniedPingGetsNoAnswer() async throws {
            try await withNetwork(policy: NetworkPolicy(), config: UserNetConfig()) { network in
                network.guest.ping(loopback, identifier: 1)
                #expect(network.guest.receivePingReply(timeout: 0.3) == nil)
                #expect(await network.events.next { $0.transport == .icmp && $0.phase != .opened } != nil)
            }
        }
    }
}

import Foundation
import Testing

@testable import NetPolicy
@testable import NetStack

private let loopback = ipv4("127.0.0.1")

private func policy(_ configure: (inout NetworkPolicy) throws -> Void) rethrows -> NetworkPolicy {
    var value = CoreRig.openPolicy
    try configure(&value)
    return value
}

extension UserNetIntegration {
    struct UserNetStackPolicyTests {
        /// Connects to the server; returns whether the guest got a connection (not a reset).
        private func reaches(_ network: TestNetwork, _ server: LoopbackServer, port: UInt16? = nil) -> Bool {
            guard let socket = network.guest.connect(to: (loopback, port ?? server.port)) else { return false }
            network.guest.abort(socket)
            return true
        }

        @Test func theDefaultPolicyDeniesLoopbackAndTheServerNeverSeesAConnection() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            try await withNetwork(policy: NetworkPolicy(), config: UserNetConfig()) { network in
                #expect(network.guest.connect(to: (loopback, server.port)) == nil)
                let denied = try #require(await network.events.next { if case .denied = $0.phase { true } else { false } })
                #expect(denied.phase == .denied(.policy(.reservedRange(.loopback, address: .v4(loopback)))))
                #expect(server.connectionCount == 0, "a denied destination is never contacted")
                network.guest.sendUDP(to: (loopback, server.port), [1])
                #expect(await network.events.next { $0.transport == .udp && $0.phase != .opened } != nil)
                #expect(server.connectionCount == 0)
            }
        }

        @Test func theFloorHoldsOnARealStackEvenWithEveryRuleAndSwitchOff() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            var wide = policy { $0.blockPrivateRanges = false }
            wide.mode = .allowListed
            wide.allowedAddresses = [try AddressRule("127.0.0.1")]
            try await withNetwork(policy: wide, config: UserNetConfig()) { network in
                #expect(network.guest.connect(to: (loopback, server.port)) == nil)
                network.guest.sendUDP(to: (loopback, server.port), [1])
                #expect(await network.events.next { $0.transport == .udp && $0.phase != .opened } != nil)
                #expect(server.connectionCount == 0, "the Mac's loopback is never contacted")
            }
        }

        @Test func denyListByPortAddressAndConnection() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            let port = server.port
            for (name, blocked, expectedAllowed) in try [
                ("port", policy { $0.blockedPorts = [PortRule(port)] }, false),
                ("other port", policy { $0.blockedPorts = [PortRule(port &+ 1)] }, true),
                ("address", policy { $0.blockedAddresses = [try AddressRule("127.0.0.0/8")] }, false),
                ("other address", policy { $0.blockedAddresses = [try AddressRule("10.0.0.0/8")] }, true),
                ("connection", policy { $0.blockedConnections = [try ConnectionRule("127.0.0.1:\(port)")] }, false),
                ("connection other port", policy { $0.blockedConnections = [try ConnectionRule("127.0.0.1:\(port &+ 1)")] }, true),
            ] {
                try await withNetwork(policy: blocked) { network in
                    #expect(reaches(network, server) == expectedAllowed, "deny-list \(name)")
                }
            }
        }

        @Test func allowListByAddressPortAndConnection() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            let port = server.port
            for (name, allowing, expectedAllowed) in try [
                (
                    "address",
                    policy {
                        $0.mode = .allowListed
                        $0.allowedAddresses = [try AddressRule("127.0.0.1")]
                    }, true
                ),
                (
                    "other address",
                    policy {
                        $0.mode = .allowListed
                        $0.allowedAddresses = [try AddressRule("10.0.0.1")]
                    }, false
                ),
                (
                    "address+port",
                    policy {
                        $0.mode = .allowListed
                        $0.allowedAddresses = [try AddressRule("127.0.0.1")]
                        $0.allowedPorts = [PortRule(port)]
                    }, true
                ),
                (
                    "address+wrong port",
                    policy {
                        $0.mode = .allowListed
                        $0.allowedAddresses = [try AddressRule("127.0.0.1")]
                        $0.allowedPorts = [PortRule(port &+ 1)]
                    }, false
                ),
                (
                    "connection",
                    policy {
                        $0.mode = .allowListed
                        $0.allowedConnections = [try ConnectionRule("127.0.0.1:\(port)")]
                    }, true
                ),
                (
                    "wrong connection",
                    policy {
                        $0.mode = .allowListed
                        $0.allowedConnections = [try ConnectionRule("127.0.0.1:\(port &+ 1)")]
                    }, false
                ),
                ("nothing allowed", policy { $0.mode = .allowListed }, false),
            ] {
                try await withNetwork(policy: allowing) { network in
                    #expect(reaches(network, server) == expectedAllowed, "allow-list \(name)")
                }
            }
        }

        @Test func denyBeatsAllowEvenForARealConnection() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            let rules = try policy {
                $0.mode = .allowListed
                $0.allowedAddresses = [try AddressRule("127.0.0.1")]
                $0.blockedConnections = [try ConnectionRule("127.0.0.1:\(server.port)")]
            }
            try await withNetwork(policy: rules) { network in
                #expect(!reaches(network, server))
                #expect(server.connectionCount == 0)
            }
        }

        @Test func domainRulesApplyThroughTheDNSProxyInBothModes() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            let resolver = StubResolver(table: ["service.test": ["127.0.0.1"], "other.test": ["127.0.0.1"]], canonical: [:])
            // Deny-list mode: the blocked name cannot even be resolved; another name for the same address still can.
            let blocking = try policy { $0.blockedDomains = [try DomainRule("service.test")] }
            try await withNetwork(policy: blocking, resolver: resolver) { network in
                try #expect(network.guest.mustResolve("service.test").code == 3)
                try #expect(network.guest.mustResolve("other.test").addresses == [loopback])
            }
            // Allow-list mode: only addresses that an allowed name resolved to may be reached.
            let allowing = try policy {
                $0.mode = .allowListed
                $0.allowedDomains = [try DomainRule("service.test")]
            }
            try await withNetwork(policy: allowing, resolver: resolver) { network in
                #expect(!reaches(network, server), "a bare address nobody resolved is not on the allow-list")
                try #expect(network.guest.mustResolve("service.test").addresses == [loopback])
                #expect(reaches(network, server), "the same address is fine once an allowed name led to it")
                let opened = try #require(await network.events.next { $0.phase == .opened })
                #expect(opened.destinationName == "service.test")
            }
        }

        @Test func aCNAMEIntoABlockedNameIsRefusedByTheProxy() async throws {
            let resolver = StubResolver(table: ["front.test": ["127.0.0.1"]], canonical: ["front.test": "tracker.test"])
            let blocking = try policy { $0.blockedDomains = [try DomainRule("tracker.test")] }
            try await withNetwork(policy: blocking, resolver: resolver) { network in
                try #expect(network.guest.mustResolve("front.test").code == 3)
            }
        }

        @Test func tighteningThePolicyAtRuntimeResetsFlowsThatNoLongerPass() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                guest.send(socket, [1, 2, 3])
                #expect(guest.receive(socket, count: 3) == [1, 2, 3])
                network.stack.updatePolicy(policy { $0.blockedPorts = [PortRule(server.port)] })
                guest.pump(timeout: 5) { socket.reset }
                #expect(socket.reset, "the existing flow is torn down so the guest reconnects and is judged afresh")
                let revoked = await network.events.next { if case .closed(.policyRevoked) = $0.phase { true } else { false } }
                #expect(revoked != nil)
                #expect(guest.connect(to: (loopback, server.port)) == nil, "and the new policy applies to new flows at once")
            }
        }

        @Test func keepingFlowsLetsThemRunOnUnderTheOldPolicy() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            try await withNetwork { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                network.stack.updatePolicy(policy { $0.blockedPorts = [PortRule(server.port)] }, existingFlows: .keep)
                #expect(guest.connect(to: (loopback, server.port)) == nil, "new flows are judged by the new policy")
                guest.send(socket, [9])
                #expect(guest.receive(socket, count: 1) == [9], "the old flow is untouched")
            }
        }

        @Test func relaxingThePolicyAdmitsNewFlows() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            var strict = CoreRig.openPolicy
            strict.blockedAddresses = [try AddressRule("127.0.0.0/8")]
            try await withNetwork(policy: strict) { network in
                #expect(!reaches(network, server))
                network.stack.updatePolicy(CoreRig.openPolicy)
                #expect(reaches(network, server))
            }
        }
    }
}

/// Whether a frame can no longer be sent into the (closed) host end of the socket pair.
private func guestSendFails(_ descriptor: Int32) -> Bool {
    ByteView.withBytes(of: [UInt8](repeating: 0, count: 14)) { frame in
        if case .failed = SocketCalls.send(descriptor, frame) { return true }
        return false
    }
}

extension UserNetIntegration {
    struct UserNetStackLifecycleTests {
        @Test func aHostPathChangeResetsOpenFlowsButNotNewOnes() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            let (changes, signal) = AsyncStream<Void>.makeStream()
            try await withNetwork(pathChanges: changes) { network in
                let guest = network.guest
                let socket = try #require(guest.connect(to: (loopback, server.port)))
                guest.send(socket, [1])
                #expect(guest.receive(socket, count: 1) == [1])
                signal.yield()
                guest.pump(timeout: 5) { socket.reset }
                #expect(socket.reset)
                #expect(await network.events.next { $0.phase == .closed(.hostPathChanged) } != nil)
                let again = try #require(guest.connect(to: (loopback, server.port)))
                guest.send(again, [2])
                #expect(guest.receive(again, count: 1) == [2], "flows started after the change use the new path")
            }
        }

        @Test func stoppingClosesFlowsReportsThemAndFinishesTheStreams() async throws {
            let server = try #require(LoopbackServer(.echo))
            defer { server.close() }
            let made = try UserNetStack.make(
                config: .loopbackReachable, policy: CoreRig.openPolicy, resolver: StubResolver(), pathChanges: { AsyncStream { _ in } })
            let events = FlowEventLog(made.stack.flowEvents)
            made.stack.start()
            let guest = GuestHarness(link: GuestLink(descriptor: made.guestDescriptor))
            try guest.boot()
            let socket = try #require(guest.connect(to: (loopback, server.port)))
            guest.send(socket, [1])
            #expect(guest.receive(socket, count: 1) == [1])
            await made.stack.stop()
            await events.waitUntilFinished()
            #expect(events.count { $0.phase == .closed(.stackStopped) } == 1)
            #expect(guestSendFails(made.guestDescriptor), "the host end of the socket pair is closed once stop() returns")
            await made.stack.stop()  // idempotent
            close(made.guestDescriptor)
        }

        @Test func aStackThatWasNeverStartedStopsCleanly() async throws {
            let made = try UserNetStack.make()
            let events = FlowEventLog(made.stack.flowEvents)
            await made.stack.stop()
            await events.waitUntilFinished()
            close(made.guestDescriptor)
        }

        @Test func startingTwiceIsHarmless() async throws {
            let made = try UserNetStack.make()
            made.stack.start()
            made.stack.start()
            await made.stack.stop()
            close(made.guestDescriptor)
        }

        @Test func aStackThatIsDroppedWithoutStoppingReleasesItsThread() async throws {
            var made: (guestDescriptor: Int32, stack: UserNetStack)? = try UserNetStack.make()
            made?.stack.start()
            let descriptor = try #require(made?.guestDescriptor)
            made = nil
            // Nothing to await: the dropped stack posts its own stop, and the loop thread closes the host end on its way out.
            let deadline = Date.now.addingTimeInterval(5)
            while !guestSendFails(descriptor), Date.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(guestSendFails(descriptor))
            close(descriptor)
        }

        @Test func invalidConfigurationsAreRejected() {
            var config = UserNetConfig()
            config.mtu = 1_000
            #expect(throws: UserNetError.invalidConfiguration("mtu must be within 1500...65535")) { try UserNetStack.make(config: config) }
            config = UserNetConfig()
            config.guestAddress = ipv4("10.0.0.2")
            #expect(throws: UserNetError.invalidConfiguration("guest address is not on the gateway's subnet")) {
                try UserNetStack.make(config: config)
            }
        }
    }
}

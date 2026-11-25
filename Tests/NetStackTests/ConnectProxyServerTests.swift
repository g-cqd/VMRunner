import Dispatch
import Foundation
import NetPolicy
import Network
import Testing

@testable import NetStack

/// Live end-to-end loopback `ConnectProxyServer` tests (V2): proves real TCP tunneling strictly to pinned authorized
/// addresses and real HTTP 403 refusal for unauthorized hosts.
struct ConnectProxyServerTests {
    @Test
    func tunnelsAuthorizedTargetAndRefusesDeniedHostOverLiveLoopback() async throws {
        // 1. Start a tiny loopback echo server representing an authorized upstream service.
        let (echoListener, echoPort) = try await Self.startEchoServer()
        defer { echoListener.cancel() }

        // 2. Configure ConnectProxyServer allowing `echo.allowed.test:<echoPort>` pinned to 127.0.0.1 (loopback floor
        // exempted strictly for this loopback integration test, matching UserNetConfig.exemptedFloorKinds).
        var policy = NetworkPolicy()
        policy.mode = .allowListed
        try policy.add("echo.allowed.test", to: .allowedDomains)
        try policy.add(String(echoPort), to: .allowedPorts)

        let loopback = try #require(IPAddress(strictLiteral: "127.0.0.1"))
        let authorizer = ConnectProxyAuthorizer(policy: policy, exemptedFloorKinds: [.loopback]) { host in
            host == "echo.allowed.test" ? [loopback] : []
        }
        let proxy = try ConnectProxyServer(authorizer: authorizer)
        let proxyPort = proxy.start()
        defer { proxy.stop() }
        #expect(proxyPort > 0)

        // 3. Allowed CONNECT establishes tunnel and echoes payload end-to-end.
        let allowedResponse = try await Self.exchange(
            port: proxyPort,
            firstSend: "CONNECT echo.allowed.test:\(echoPort) HTTP/1.1\r\nHost: echo.allowed.test:\(echoPort)\r\n\r\n",
            secondSend: "hello-vmrunner"
        )
        #expect(allowedResponse.header.hasPrefix("HTTP/1.1 200 Connection Established"))
        #expect(allowedResponse.body == "hello-vmrunner")

        // 4. Denied CONNECT returns HTTP 403 Forbidden and closes cleanly.
        let deniedResponse = try await Self.exchange(
            port: proxyPort,
            firstSend: "CONNECT evil.example:\(echoPort) HTTP/1.1\r\nHost: evil.example:\(echoPort)\r\n\r\n",
            secondSend: nil
        )
        #expect(deniedResponse.header.hasPrefix("HTTP/1.1 403 Forbidden"))
    }

    private static func startEchoServer() async throws -> (NWListener, UInt16) {
        // Network.framework NWListener requires a queue.
        // swiftlint:disable:next no_dispatch_queue
        let echoQueue = DispatchQueue(label: "vmrunner.test.echo")
        let echoParams = NWParameters.tcp
        echoParams.acceptLocalOnly = true
        echoParams.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let echoListener = try NWListener(using: echoParams)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            echoListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    echoListener.stateUpdateHandler = nil
                    continuation.resume(returning: echoListener.port?.rawValue ?? 0)
                case .failed(let error):
                    echoListener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            echoListener.newConnectionHandler = { conn in
                conn.start(queue: echoQueue)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                    if let data {
                        conn.send(content: data, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                    } else {
                        conn.cancel()
                    }
                }
            }
            echoListener.start(queue: echoQueue)
        }
        return (echoListener, port)
    }

    private static func exchange(
        port: UInt16,
        firstSend: String,
        secondSend: String?
    ) async throws -> (header: String, body: String) {
        let nwPort = try #require(NWEndpoint.Port(rawValue: port))
        return try await withCheckedThrowingContinuation { continuation in
            // Network.framework NWConnection requires a queue.
            // swiftlint:disable:next no_dispatch_queue
            let queue = DispatchQueue(label: "vmrunner.test.client")
            let conn = NWConnection(host: .ipv4(.loopback), port: nwPort, using: .tcp)
            conn.stateUpdateHandler = { state in
                if case .ready = state {
                    conn.send(
                        content: Data(firstSend.utf8),
                        completion: .contentProcessed { _ in
                            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                                let header = data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
                                guard let secondSend, header.hasPrefix("HTTP/1.1 200") else {
                                    conn.cancel()
                                    continuation.resume(returning: (header, ""))
                                    return
                                }
                                conn.send(
                                    content: Data(secondSend.utf8),
                                    completion: .contentProcessed { _ in
                                        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { bodyData, _, _, _ in
                                            let body = bodyData.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
                                            conn.cancel()
                                            continuation.resume(returning: (header, body))
                                        }
                                    })
                            }
                        })
                } else if case .failed(let err) = state {
                    conn.cancel()
                    continuation.resume(throwing: err)
                }
            }
            conn.start(queue: queue)
        }
    }
}

import Dispatch
import Foundation
import NetPolicy
import Network

/// Live loopback HTTP `CONNECT` proxy tunnel driven by `ConnectProxyAuthorizer` (V2 / N-V3):
/// - Listens strictly on IPv4 loopback (`127.0.0.1`, ephemeral port `0` by default) or an injected stream.
/// - Reads a bounded `CONNECT host:port HTTP/1.1` header (max 8 KiB), resolves names host-side, and authorizes via
///   `ConnectProxyAuthorizer`.
/// - Dials **strictly** the validated pinned `IPAddress` returned by `ConnectProxyAuthorizer` (never re-resolves the
///   hostname, eliminating DNS rebinding TOCTOU) and relays bytes bidirectionally until either peer closes.
package final class ConnectProxyServer: @unchecked Sendable {  // all mutable state accessed exclusively on `queue`
    private let authorizer: ConnectProxyAuthorizer
    // Network.framework NWListener/NWConnection requires a queue.
    // swiftlint:disable:next no_dispatch_queue
    private let queue = DispatchQueue(label: "vmrunner.connect-proxy", qos: .userInitiated)
    private let listener: NWListener
    private let readySem = DispatchSemaphore(value: 0)
    private var boundPort: UInt16 = 0

    package var port: UInt16 { boundPort }

    package init(authorizer: ConnectProxyAuthorizer, port: UInt16 = 0) throws {
        self.authorizer = authorizer
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        self.listener = try NWListener(using: params)
    }

    /// Starts accepting loopback `CONNECT` connections and waits up to 2 s for the ephemeral port assignment.
    @discardableResult
    package func start() -> UInt16 {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.boundPort = self.listener.port?.rawValue ?? 0
                self.readySem.signal()
            } else if case .failed = state {
                self.readySem.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] client in
            guard let self else {
                client.cancel()
                return
            }
            self.handle(client)
        }
        listener.start(queue: queue)
        _ = readySem.wait(timeout: .now() + 2.0)
        return boundPort
    }

    package func stop() {
        listener.cancel()
    }

    private func handle(_ client: NWConnection) {
        client.start(queue: queue)
        receiveHeader(from: client, accumulated: Data())
    }

    private func receiveHeader(from client: NWConnection, accumulated: Data) {
        let remaining = ConnectProxyAuthorizer.maximumHeaderBytes - accumulated.count
        guard remaining > 0 else {
            let reply = ConnectProxyAuthorizer.httpResponse(for: .deny(statusCode: 400, reason: "header too large"))
            sendAndClose(reply, on: client)
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                client.cancel()
                return
            }
            if error != nil {
                client.cancel()
                return
            }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }
            let delimiter = Data("\r\n\r\n".utf8)
            if let range = buffer.range(of: delimiter) {
                let headerBytes = buffer[..<range.upperBound]
                let trailing = Data(buffer[range.upperBound...])
                let raw = String(bytes: headerBytes, encoding: .utf8) ?? ""
                Task { [weak self] in
                    guard let self else {
                        client.cancel()
                        return
                    }
                    let outcome = await self.authorizer.authorize(raw)
                    self.queue.async {
                        self.apply(outcome, on: client, trailing: trailing)
                    }
                }
                return
            }
            if isComplete {
                let reply = ConnectProxyAuthorizer.httpResponse(for: .deny(statusCode: 400, reason: "incomplete request"))
                self.sendAndClose(reply, on: client)
                return
            }
            self.receiveHeader(from: client, accumulated: buffer)
        }
    }

    private func apply(_ outcome: ConnectProxyAuthorizer.Outcome, on client: NWConnection, trailing: Data) {
        switch outcome {
        case .deny:
            sendAndClose(ConnectProxyAuthorizer.httpResponse(for: outcome), on: client)
        case .allow(let target, let pinnedAddresses):
            guard let first = pinnedAddresses.first,
                let endpointPort = NWEndpoint.Port(rawValue: target.port)
            else {
                sendAndClose(
                    ConnectProxyAuthorizer.httpResponse(for: .deny(statusCode: 502, reason: "no dialable address")),
                    on: client
                )
                return
            }
            let endpointHost = NWEndpoint.Host(first.description)
            let upstream = NWConnection(host: endpointHost, port: endpointPort, using: .tcp)
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    upstream.stateUpdateHandler = nil
                    let okBytes = Data(ConnectProxyAuthorizer.httpResponse(for: outcome).utf8)
                    client.send(
                        content: okBytes,
                        completion: .contentProcessed { sendErr in
                            if sendErr != nil {
                                client.cancel()
                                upstream.cancel()
                                return
                            }
                            if !trailing.isEmpty {
                                upstream.send(content: trailing, completion: .contentProcessed { _ in })
                            }
                            self.pump(from: client, to: upstream)
                            self.pump(from: upstream, to: client)
                        })
                case .failed:
                    upstream.stateUpdateHandler = nil
                    self.sendAndClose(
                        ConnectProxyAuthorizer.httpResponse(for: .deny(statusCode: 502, reason: "upstream connect failed")),
                        on: client
                    )
                    upstream.cancel()
                default:
                    break
                }
            }
            upstream.start(queue: queue)
        }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
            guard let self else {
                source.cancel()
                destination.cancel()
                return
            }
            if let data, !data.isEmpty {
                destination.send(
                    content: data,
                    completion: .contentProcessed { sendErr in
                        if sendErr != nil || isComplete || error != nil {
                            source.cancel()
                            destination.cancel()
                        } else {
                            self.pump(from: source, to: destination)
                        }
                    })
                return
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func sendAndClose(_ response: String, on client: NWConnection) {
        client.send(
            content: Data(response.utf8), isComplete: true,
            completion: .contentProcessed { _ in
                client.cancel()
            })
    }
}

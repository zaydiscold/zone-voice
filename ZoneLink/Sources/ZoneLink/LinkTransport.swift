// by zayd/cold @ zayd.wtf

import Foundation
import IrohLib
import ZoneCore

/// The computer to dial.
public struct LinkPeer: Sendable, Equatable {
    /// The computer's iroh endpoint id, as text.
    public var endpointID: String
    /// Its relay, when the pairing link pinned one. Otherwise iroh's discovery finds it.
    public var relay: String?
    /// Known socket addresses. Empty in the app; tests use it to stay off the internet.
    public var addresses: [String]

    public init(endpointID: String, relay: String? = nil, addresses: [String] = []) {
        self.endpointID = endpointID
        self.relay = relay
        self.addresses = addresses
    }
}

public struct LinkTransportConfiguration: Sendable {
    public enum Network: Sendable {
        /// iroh's defaults: n0's relays and discovery. What the app uses.
        case n0
        /// No relay and no discovery: only the addresses given in `LinkPeer`. For tests.
        case isolated
    }

    public var network: Network
    /// The endpoint is closed after this long with no session.
    public var idleSeconds: TimeInterval
    /// How long to wait for the connection before calling the computer unreachable.
    public var connectSeconds: TimeInterval
    /// How long to wait for any one frame.
    public var frameSeconds: TimeInterval

    public init(network: Network = .n0, idleSeconds: TimeInterval = 30, connectSeconds: TimeInterval = 20,
                frameSeconds: TimeInterval = LinkProtocol.idleSeconds) {
        self.network = network
        self.idleSeconds = idleSeconds
        self.connectSeconds = connectSeconds
        self.frameSeconds = frameSeconds
    }
}

public enum LinkTransportError: Error, Equatable {
    /// The phone's key could not be read or saved (for example before the first unlock).
    case keyUnavailable
}

/// The phone's iroh endpoint and the sessions that run over it.
///
/// Nothing exists until the first `sync`: no endpoint, no socket, no key. The endpoint is made
/// on demand, shared by sessions that overlap, and closed after about 30 seconds with none,
/// so an unpaired or idle phone holds no network resources at all.
public actor LinkTransport {
    private let secrets: LinkSecretStore
    private let configuration: LinkTransportConfiguration
    private var endpoint: Endpoint?
    private var binding: Task<Endpoint, Error>?
    private var sessions = 0
    private var lastUsed = Date.distantPast
    private var idleTimer: Task<Void, Never>?

    public init(secrets: LinkSecretStore, configuration: LinkTransportConfiguration = LinkTransportConfiguration()) {
        self.secrets = secrets
        self.configuration = configuration
    }

    /// True while an endpoint is open.
    public var isRunning: Bool { endpoint != nil }

    /// The phone's own endpoint id: the public half of its key, 64 lowercase hex characters.
    /// This is what a paired computer pins. Makes the key on first use; touches no network.
    public func phoneEndpointID() throws -> String {
        try SecretKey.fromBytes(bytes: try secretKey()).public().description
    }

    /// True when `text` is an endpoint id iroh can dial.
    public nonisolated static func isEndpointID(_ text: String) -> Bool {
        (try? EndpointId.fromString(s: text)) != nil
    }

    /// One session with one computer: connect, `hello`, send what the delegate says is pending,
    /// `bye`. Throws `LinkSessionError`, `LinkTransportError` when the phone's key cannot be
    /// used, or `CancellationError` when the calling task is cancelled.
    public func sync(with peer: LinkPeer, phone: LinkPhone, pairSecret: String?,
                     delegate: LinkSessionDelegate) async throws -> LinkSessionOutcome {
        sessions += 1
        defer {
            sessions -= 1
            lastUsed = Date()
            scheduleIdleShutdown()
        }

        let endpoint: Endpoint
        let address: EndpointAddr
        do {
            address = EndpointAddr(id: try EndpointId.fromString(s: peer.endpointID), relayUrl: peer.relay, addresses: peer.addresses)
            endpoint = try await openEndpoint()
        } catch let error as LinkTransportError {
            throw error
        } catch {
            throw LinkSessionError.unreachable(Self.describe(error))
        }

        // A connect that is still waiting cannot be cancelled from here. If it finishes after
        // the deadline, the late connection is closed instead of being left open.
        let pending = PendingConnection()
        let connection: Connection
        do {
            connection = try await LinkDeadline.run(seconds: configuration.connectSeconds, onExpire: { pending.abandon() }) {
                let connection = try await endpoint.connect(addr: address, alpn: LinkProtocol.alpn)
                pending.arrived(connection)
                return connection
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LinkSessionError.unreachable(Self.describe(error))
        }
        let hangUp: @Sendable () -> Void = { try? connection.close(errorCode: 1, reason: Data("stalled".utf8)) }
        defer { try? connection.close(errorCode: 0, reason: Data("done".utf8)) }

        do {
            let stream = LinkIrohStream(try await LinkDeadline.run(seconds: 10, onExpire: hangUp) {
                try await connection.openBi()
            })
            let outcome = try await LinkSession.run(over: stream, phone: phone, pairSecret: pairSecret, delegate: delegate,
                                                    frameTimeout: configuration.frameSeconds, onStall: hangUp)
            // After `bye` the computer finishes its half. Waiting for that (briefly) means the
            // close below cannot cut off the last frame on its way out.
            _ = try? await LinkDeadline.run(seconds: 5, onExpire: hangUp) { try await stream.drain() }
            return outcome
        } catch let error as LinkSessionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LinkSessionError.connectionLost(Self.describe(error))
        }
    }

    /// Closes the endpoint now. The next `sync` opens a new one.
    public func shutdown() async {
        idleTimer?.cancel()
        idleTimer = nil
        guard let open = endpoint else { return }
        endpoint = nil
        try? await open.close()
    }

    // MARK: Endpoint

    private func openEndpoint() async throws -> Endpoint {
        idleTimer?.cancel()
        idleTimer = nil
        if let open = endpoint {
            // The idle timer does not run while iOS has the app suspended. An endpoint that sat
            // through that is closed here instead of being trusted.
            let fresh = sessions > 1 || Date().timeIntervalSince(lastUsed) <= configuration.idleSeconds
            if fresh, !open.isClosed() { return open }
            endpoint = nil
            try? await open.close()
        }
        if let binding { return try await binding.value }
        let key = try secretKey()
        let network = configuration.network
        let task = Task { () throws -> Endpoint in
            switch network {
            case .n0:
                return try await Endpoint.bind(options: EndpointOptions(preset: presetN0(), secretKey: key))
            case .isolated:
                return try await Endpoint.bind(options: EndpointOptions(preset: presetMinimal(), secretKey: key))
            }
        }
        binding = task
        defer { binding = nil }
        let bound = try await task.value
        endpoint = bound
        return bound
    }

    private func scheduleIdleShutdown() {
        idleTimer?.cancel()
        idleTimer = nil
        guard sessions == 0, endpoint != nil else { return }
        let seconds = configuration.idleSeconds
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() async {
        guard sessions == 0 else { return }
        await shutdown()
    }

    // MARK: Key

    /// The phone's iroh secret key, made once and kept in the secret store. A store that cannot
    /// be read (locked since restart) is an error, never a reason to make a second identity.
    private func secretKey() throws -> Data {
        if let key = secrets.secret(LinkSecretName.phoneKey), key.count == 32 { return key }
        let key = SecretKey.generate().toBytes()
        guard secrets.setSecret(key, for: LinkSecretName.phoneKey) else { throw LinkTransportError.keyUnavailable }
        return key
    }

    private static func describe(_ error: Error) -> String {
        if let iroh = error as? IrohError { return iroh.message() }
        return String(describing: error)
    }
}

/// A connection that may arrive after its caller stopped waiting.
private final class PendingConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: Connection?
    private var abandoned = false

    func arrived(_ connection: Connection) {
        lock.lock()
        let late = abandoned
        if !late { self.connection = connection }
        lock.unlock()
        if late { try? connection.close(errorCode: 2, reason: Data("late".utf8)) }
    }

    func abandon() {
        lock.lock()
        abandoned = true
        let open = connection
        connection = nil
        lock.unlock()
        try? open?.close(errorCode: 2, reason: Data("late".utf8))
    }
}

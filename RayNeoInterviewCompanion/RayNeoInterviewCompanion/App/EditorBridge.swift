import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Counters for the editor link (shown in Settings and the diagnostics timeline).
nonisolated struct EditorLinkMetrics: Equatable, Sendable {
    var pairings = 0
    var resumes = 0
    var authFailures = 0
    var rejectedMessages = 0
    var rateLimited = 0
    var heartbeatTimeouts = 0
    var disconnects = 0
    var lastEventToCaptionMs: Double?
}

/// The iPhone end of the VS Code link. Authenticated and encrypted (see EditorSecurity.swift); listens only
/// while the user allows it and the app is active (iOS suspends background apps: no background connectivity
/// is promised). One editor at a time; a newer authenticated editor replaces an older connection.
@MainActor @Observable final class EditorBridge {
    private(set) var enabled = false
    private(set) var suspended = false
    private(set) var pairing: (code: String, expires: Date)?
    private(set) var port: UInt16?
    private(set) var connectedEditor: TrustedEditor?
    private(set) var status = "Off"
    private(set) var metrics = EditorLinkMetrics()
    private(set) var trusted: [TrustedEditor] = []
    /// Authenticated, decrypted editor events.
    var onEvent: (EditorEvent) -> Void = { _ in }
    var now: () -> Date = Date.init
    static let preferredPort: UInt16 = 48_654
    static let heartbeatTimeout: TimeInterval = 30

    private let trust: any EditorTrustStore
    private var listener: NWListener?
    private var session: EditorServerSession?
    private var transmit: ((Data) -> Void)?
    private var closeConnection: (() -> Void)?
    private var limiter = EditorRateLimiter()
    private var lastReceived: Date?
    private var watchdog: Task<Void, Never>?
    private var expectation: [String: Any]?

    init(trust: any EditorTrustStore = KeychainTrustStore()) {
        self.trust = trust
        trusted = trust.all()
    }

    var connected: Bool { connectedEditor != nil }
    var shouldListen: Bool { enabled && !suspended }

    // MARK: Controls

    func setEnabled(_ on: Bool) {
        enabled = on
        on ? startListening() : stopListening(reason: "editor link turned off")
    }

    /// Opens a 2-minute, single-use pairing window and returns the code to type into VS Code.
    @discardableResult
    func startPairing() -> String {
        if !enabled { setEnabled(true) }
        let code = EditorCrypto.newPairingCode()
        pairing = (code, now().addingTimeInterval(EditorCrypto.codeLifetime))
        status = "Pairing: enter \(code) in VS Code (2 minutes)"
        DiagnosticLog.shared.record(.session, "Editor pairing window opened (2 min)")
        return code
    }

    func cancelPairing() { pairing = nil; refreshStatus() }

    /// Revokes an editor: its key is deleted and, if connected, the connection ends.
    func forget(_ deviceID: String) {
        trust.remove(deviceID)
        trusted = trust.all()
        if connectedEditor?.deviceID == deviceID { close(reason: "editor forgotten") }
        DiagnosticLog.shared.record(.session, "Editor forgotten (trust revoked)")
    }

    func disconnect() { close(reason: "disconnected on the iPhone") }

    /// iOS scene phase: listening stops in the background and resumes when active; VS Code reconnects itself.
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if value { stopListening(reason: "app in background") } else if enabled { startListening() }
    }

    /// The current code step, for the editor to check (resent after every reconnection).
    func expect(blockID: String, language: String, structures: [String]) {
        expectation = ["type": "expect", "blockID": blockID, "language": language, "structures": structures]
        if connected, let expectation { send(expectation) }
    }

    func send(_ body: [String: Any]) {
        guard var current = session, current.authenticated, let transmit,
              let envelope = try? current.seal(body, now: now()), let data = try? JSONEncoder().encode(envelope) else { return }
        session = current
        transmit(data + Data([0x0A]))
    }

    // MARK: Connection handling (network-independent, so it can be tested without sockets)

    private struct Pending {
        var session: EditorServerSession
        var transmit: (Data) -> Void
        var close: () -> Void
    }
    /// Unauthenticated connections each have their own buffer and handshake; they never touch the active one.
    private var pendings: [Int: Pending] = [:]
    private var buffers: [Int: Data] = [:]
    private var activeToken: Int?
    private var nextToken = 0

    /// A new connection: the handshake starts with the server hello. Returns its token.
    @discardableResult
    func accept(transmit: @escaping (Data) -> Void, close: @escaping () -> Void) -> Int {
        let pairingOpen = pairing.map { $0.expires > now() } == true
        if pairing != nil, !pairingOpen { pairing = nil }
        guard pendings.count < 4 else { close(); return -1 } // a flood of half-open connections is refused
        nextToken += 1
        var fresh = EditorServerSession(pairingCode: pairingOpen ? pairing?.code : nil)
        fresh.service = "RayPrompt-\(Self.deviceTag)"
        pendings[nextToken] = Pending(session: fresh, transmit: transmit, close: close)
        buffers[nextToken] = Data()
        if let data = try? JSONEncoder().encode(fresh.hello) { transmit(data + Data([0x0A])) }
        return nextToken
    }

    /// Bytes received on connection `token` (newline-delimited JSON).
    func receive(_ data: Data, token: Int) {
        guard pendings[token] != nil || token == activeToken else { return }
        buffers[token, default: Data()].append(data)
        while let line = nextLine(token) {
            handleLine(line, token: token)
            guard pendings[token] != nil || token == activeToken else { return }
        }
        if (buffers[token]?.count ?? 0) > EditorCrypto.maxLine { drop(token, reason: "message too large") }
    }

    private func nextLine(_ token: Int) -> Data? {
        guard var buffer = buffers[token], let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        buffers[token] = buffer
        return line
    }

    private func handleLine(_ line: Data, token: Int) {
        guard line.count <= EditorCrypto.maxLine else { return drop(token, reason: "message too large") }
        if var pending = pendings[token] {
            guard let message = try? JSONDecoder().decode(EditorHandshake.self, from: line) else { return drop(token, reason: "malformed handshake") }
            if message.type == "pair" { pairing = nil } // single use, success or not
            let (reply, outcome) = pending.session.handshake(message, trusted: trust.all(), now: now())
            if let data = try? JSONEncoder().encode(reply) { pending.transmit(data + Data([0x0A])) }
            switch outcome {
            case .rejected(let reason):
                metrics.authFailures += 1
                status = "Editor rejected: \(reason)"
                drop(token, reason: "authentication rejected (\(reason))")
            case .paired(let editor):
                trust.save(editor)
                trusted = trust.all()
                metrics.pairings += 1
                activate(pending, token: token, editor: editor, how: "paired")
            case .resumed(let deviceID):
                metrics.resumes += 1
                activate(pending, token: token, editor: trust.all().first { $0.deviceID == deviceID }, how: "reconnected")
            }
            return
        }
        guard token == activeToken, var current = session else { return }
        guard limiter.allow(at: now()) else {
            metrics.rateLimited += 1
            return close(reason: "rate limit exceeded")
        }
        do {
            let envelope = try JSONDecoder().decode(EditorEnvelope.self, from: line)
            let event = try current.open(envelope, now: now())
            session = current
            lastReceived = now()
            switch event.type {
            case "ping": send(["type": "pong", "id": event.id ?? 0])
            case "bye": close(reason: "editor closed the connection")
            default: onEvent(event)
            }
        } catch {
            metrics.rejectedMessages += 1
            DiagnosticLog.shared.record(.session, "Editor message rejected: \(error.localizedDescription)")
            close(reason: (error as? EditorLinkError)?.errorDescription ?? "invalid message")
        }
    }

    private func activate(_ pending: Pending, token: Int, editor: TrustedEditor?, how: String) {
        if activeToken != nil { closeConnection?() } // a newer authenticated editor replaces the older connection
        pendings[token] = nil
        activeToken = token
        session = pending.session
        transmit = pending.transmit
        closeConnection = pending.close
        connectedEditor = editor
        limiter = EditorRateLimiter()
        lastReceived = now()
        status = "Editor \(how): \(editor?.name ?? "VS Code")"
        DiagnosticLog.shared.record(.session, "Editor \(how) (encrypted session)")
        send(["type": "status", "state": "connected"])
        if let expectation { send(expectation) }
        startWatchdog()
    }

    /// An unauthenticated connection is closed without affecting the active editor.
    private func drop(_ token: Int, reason: String) {
        if token == activeToken { return close(reason: reason) }
        DiagnosticLog.shared.record(.session, "Editor connection refused: \(reason)")
        pendings[token]?.close()
        pendings[token] = nil
        buffers[token] = nil
    }

    /// No message (pings included) for 30 s: the editor is gone (sleep, network change); it reconnects with backoff.
    @discardableResult
    func checkHeartbeat() -> Bool {
        guard connected, let lastReceived, now().timeIntervalSince(lastReceived) > Self.heartbeatTimeout else { return true }
        metrics.heartbeatTimeouts += 1
        close(reason: "heartbeat lost")
        return false
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.checkHeartbeat() else { return }
            }
        }
    }

    private func close(reason: String) {
        if connected { metrics.disconnects += 1 }
        watchdog?.cancel()
        closeConnection?()
        if let activeToken { buffers[activeToken] = nil }
        activeToken = nil
        session = nil
        transmit = nil
        closeConnection = nil
        connectedEditor = nil
        status = shouldListen ? "Waiting for VS Code (\(reason))" : "Off (\(reason))"
        if reason != "app in background", reason != "editor link turned off" { DiagnosticLog.shared.record(.session, "Editor link closed: \(reason)") }
    }

    /// Everything, pending handshakes included (listener stopped).
    private func closeAll(reason: String) {
        for token in Array(pendings.keys) { drop(token, reason: reason) }
        close(reason: reason)
    }

    private func refreshStatus() {
        status = connected ? "Editor connected: \(connectedEditor?.name ?? "VS Code")" : (shouldListen ? "Waiting for VS Code" : "Off")
    }

    // MARK: Network.framework

    private func startListening() {
        guard shouldListen, listener == nil else { return refreshStatus() }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = (try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.preferredPort)!)) ?? (try? NWListener(using: parameters))
        guard let listener else { status = "Editor link unavailable"; return }
        listener.service = NWListener.Service(name: "RayPrompt-\(Self.deviceTag)", type: "_codetutor._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready: self.port = listener.port?.rawValue; self.refreshStatus()
                case .failed(let error): self.status = "Editor link failed: \(error.localizedDescription)"; self.stopListening(reason: "listener failed")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.attach(connection) } }
        listener.start(queue: .main)
        self.listener = listener
        DiagnosticLog.shared.record(.session, "Editor link listening")
    }

    private func stopListening(reason: String) {
        listener?.cancel()
        listener = nil
        port = nil
        closeAll(reason: reason)
    }

    private func attach(_ new: NWConnection) {
        guard shouldListen else { return new.cancel() }
        new.start(queue: .main)
        let token = accept(transmit: { data in new.send(content: data, completion: .contentProcessed { _ in }) }, close: { new.cancel() })
        guard token > 0 else { return }
        receiveLoop(new, token: token)
    }

    private func receiveLoop(_ connection: NWConnection, token: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.receive(data, token: token) }
                if complete || error != nil {
                    if token == self.activeToken { self.close(reason: "editor disconnected") } else { self.drop(token, reason: "closed") }
                    return
                }
                self.receiveLoop(connection, token: token)
            }
        }
    }

    /// Short, stable tag for the Bonjour name so VS Code can find this iPhone after a network change.
    static var deviceTag: String {
        #if canImport(UIKit)
        return String((UIDevice.current.identifierForVendor?.uuidString ?? "000000").prefix(6))
        #else
        return "000000"
        #endif
    }

    /// The iPhone's Wi-Fi address, shown for the first pairing.
    static func wifiAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let address = interface.pointee.ifa_addr.pointee
            guard address.sa_family == UInt8(AF_INET), String(cString: interface.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.pointee.ifa_addr, socklen_t(address.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }
}

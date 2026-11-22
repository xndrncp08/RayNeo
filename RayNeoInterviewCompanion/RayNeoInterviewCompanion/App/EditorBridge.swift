import Foundation
import Network

/// Protocol state for one editor connection (pure; the network layer only moves bytes).
///
/// 1. iPhone → editor: `{"type":"challenge","nonce":…}`
/// 2. editor → iPhone: `{"type":"hello","mac":HMAC-SHA256(code, nonce)}` — the 6-digit code never travels.
/// 3. iPhone → editor: `{"type":"expect","blockID":…,"language":…,"structures":[…]}` for the current code step.
/// 4. editor → iPhone: `{"type":"progress","blockID":…,"file":"name.js","present":[…],"errors":n}`.
nonisolated struct EditorSession: Sendable {
    let code: String
    let nonce: String
    private(set) var paired = false
    private(set) var expectation: EditorMessage?

    init(code: String, nonce: String = UUID().uuidString) {
        self.code = code
        self.nonce = nonce
    }

    var challenge: EditorMessage { EditorMessage(type: "challenge", nonce: nonce) }

    /// Sets the step the editor should check; returns the message to send if paired.
    mutating func expect(blockID: String, language: String, structures: [String]) -> EditorMessage? {
        expectation = EditorMessage(type: "expect", blockID: blockID, language: language, structures: structures)
        return paired ? expectation : nil
    }

    /// Handles one received line. `close` ends the connection (bad pairing or garbage).
    mutating func receive(_ line: Data) -> (replies: [EditorMessage], progress: EditorProgress?, close: Bool) {
        guard line.count <= 16_384, let message = try? JSONDecoder().decode(EditorMessage.self, from: line) else { return ([], nil, true) }
        switch message.type {
        case "hello":
            guard EditorMessage.verify(message.mac, code: code, nonce: nonce) else { return ([], nil, true) }
            paired = true
            return ([EditorMessage(type: "paired")] + (expectation.map { [$0] } ?? []), nil, false)
        case "progress":
            guard paired, let blockID = message.blockID, let present = message.present else { return ([], nil, !paired) }
            return ([], EditorProgress(blockID: blockID, file: (message.file as NSString?)?.lastPathComponent ?? "",
                                       language: message.language, present: present, errors: message.errors), false)
        default:
            return ([], nil, !paired)
        }
    }
}

/// Optional, explicitly paired link to an editor companion (see Tools/vscode-code-tutor). Local network
/// only, listening only while pairing is on, one editor at a time. Messages are not encrypted: they
/// carry only the step's expected structures (generated code), file names, booleans and error counts.
@MainActor @Observable final class EditorBridge {
    private(set) var listening = false
    private(set) var pairingCode = ""
    private(set) var port: UInt16?
    private(set) var paired = false
    private(set) var status = "Not paired"
    private(set) var lastProgress: EditorProgress?
    var onProgress: (EditorProgress) -> Void = { _ in }

    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: EditorSession?
    private var buffer = Data()
    private var pendingExpectation: (blockID: String, language: String, structures: [String])?

    func start() {
        guard listener == nil else { return }
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: "RayNeo Code Tutor", type: "_codetutor._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = listener.port?.rawValue; self.status = "Waiting for the editor (code \(self.pairingCode))"
                    case .failed(let error): self.status = "Pairing failed: \(error.localizedDescription)"; self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue: .main)
            self.listener = listener
            listening = true
            DiagnosticLog.shared.record(.session, "Editor pairing listener started")
        } catch {
            status = "Pairing unavailable: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        connection?.cancel(); connection = nil
        session = nil; paired = false; listening = false; port = nil
        status = "Not paired"
    }

    /// The current code step's expected structures (sent when paired, kept for a later pairing).
    func expect(blockID: String, language: String, structures: [String]) {
        pendingExpectation = (blockID, language, structures)
        if let message = session?.expect(blockID: blockID, language: language, structures: structures) { send(message) }
    }

    private func accept(_ new: NWConnection) {
        connection?.cancel() // one editor at a time
        connection = new
        var session = EditorSession(code: pairingCode)
        if let pending = pendingExpectation { _ = session.expect(blockID: pending.blockID, language: pending.language, structures: pending.structures) }
        self.session = session
        paired = false
        buffer = Data()
        new.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === new else { return }
                if case .failed = state { self.disconnected() }
                if case .cancelled = state { self.disconnected() }
            }
        }
        new.start(queue: .main)
        send(session.challenge)
        receive(on: new)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data { self.buffer.append(data) }
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer[..<newline]
                    self.buffer.removeSubrange(...newline)
                    self.handle(Data(line))
                }
                if self.buffer.count > 16_384 { return connection.cancel() }
                if complete || error != nil { return connection.cancel() }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ line: Data) {
        guard var session else { return }
        let result = session.receive(line)
        self.session = session
        if result.close { DiagnosticLog.shared.record(.session, "Editor connection rejected"); connection?.cancel(); return }
        if session.paired, !paired {
            paired = true
            status = "Editor paired"
            DiagnosticLog.shared.record(.session, "Editor paired")
        }
        result.replies.forEach(send)
        if let progress = result.progress {
            lastProgress = progress
            status = "Editor: \(progress.file), \(progress.present.filter { $0 }.count)/\(progress.present.count) structures"
                + (progress.errors.map { ", \($0) error(s)" } ?? "")
            onProgress(progress)
        }
    }

    private func disconnected() {
        connection = nil
        session = nil
        paired = false
        lastProgress = nil
        status = listening ? "Editor disconnected (code still visible; waiting for it to reconnect)" : "Not paired"
        DiagnosticLog.shared.record(.session, "Editor disconnected")
    }

    private func send(_ message: EditorMessage) {
        guard let connection, var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// The iPhone's Wi-Fi address, shown so the editor knows where to connect.
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

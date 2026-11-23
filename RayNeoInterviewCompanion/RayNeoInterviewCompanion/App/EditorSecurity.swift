import CryptoKit
import Foundation
import Security

/// RayPrompt editor link security (iPhone side; mirrors Tools/vscode-code-tutor/protocol.js).
///
/// - Pairing: X25519 key agreement; HKDF-SHA256 over the shared secret with the server nonce as salt and
///   SHA-256 of the one-time pairing code in the info. The code is 10 base32 characters (~50 bits), valid
///   2 minutes and single use (one wrong attempt invalidates it). Both sides prove the code with HMACs over
///   the transcript; a long-term trust key is derived and kept in the Keychain (30 days).
/// - Reconnection: fresh ephemeral keys every session, authenticated with the trust key (forward secrecy).
/// - Messages: ChaCha20-Poly1305, per-direction counter nonces, strict sequence numbers (no replay or
///   reordering) and timestamps (stale messages rejected). Same-Wi-Fi access is not the security boundary.
nonisolated enum EditorCrypto {
    static let version = 1
    static let maxLine = 32 * 1024
    static let maxSkew: TimeInterval = 120
    static let codeLifetime: TimeInterval = 120
    static let trustLifetime: TimeInterval = 30 * 24 * 3600

    struct SessionKeys: Equatable, Sendable {
        var c2s: Data
        var s2c: Data
        var auth: Data
    }

    static func normalizeCode(_ code: String) -> String {
        code.uppercased().filter { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
    }

    /// 10 random base32 characters, shown as XXXXX-XXXXX.
    static func newPairingCode() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bytes = [UInt8](repeating: 0, count: 10)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let code = String(bytes.map { alphabet[Int($0) % 32] })
        return String(code.prefix(5)) + "-" + String(code.suffix(5))
    }

    static func transcript(serverKey: Data, clientKey: Data, nonce: Data, deviceID: String) -> Data {
        Data("rayprompt v\(version)|".utf8) + serverKey + clientKey + nonce + Data(deviceID.utf8)
    }

    static func deriveKeys(shared: SharedSecret, nonce: Data, secret: Data, mode: String) -> SessionKeys {
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: Data("rayprompt \(mode) v\(version)".utf8) + secret,
                                                 outputByteCount: 96)
        let bytes = key.withUnsafeBytes { Data($0) }
        return SessionKeys(c2s: bytes.prefix(32), s2c: bytes.subdata(in: 32..<64), auth: bytes.subdata(in: 64..<96))
    }

    static func trustKey(shared: SharedSecret, nonce: Data, codeHash: Data) -> Data {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: Data("rayprompt trust v\(version)".utf8) + codeHash,
                                       outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

    static func mac(_ key: Data, _ label: String, _ transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + transcript, using: SymmetricKey(data: key)))
    }

    static func verify(_ mac: String?, key: Data, label: String, transcript: Data) -> Bool {
        guard let mac, let given = Data(base64Encoded: mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data(label.utf8) + transcript, using: SymmetricKey(data: key))
    }

    static func nonce(_ seq: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 { bytes[11 - index] = UInt8((UInt64(seq) >> (8 * UInt64(index))) & 0xFF) }
        return Data(bytes)
    }

    static func seal(_ plain: Data, key: Data, seq: Int, direction: String) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), nonce: ChaChaPoly.Nonce(data: nonce(seq)),
                                      authenticating: Data("rayprompt \(direction) \(seq)".utf8))
        return box.ciphertext + box.tag
    }

    static func open(_ box: Data, key: Data, seq: Int, direction: String) throws -> Data {
        guard box.count >= 16 else { throw EditorLinkError.badMessage("too short") }
        let sealed = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce(seq)), ciphertext: box.dropLast(16), tag: box.suffix(16))
        return try ChaChaPoly.open(sealed, using: SymmetricKey(data: key), authenticating: Data("rayprompt \(direction) \(seq)".utf8))
    }
}

nonisolated enum EditorLinkError: Error, Equatable, LocalizedError {
    case badMessage(String), replay, stale, tooLarge, rateLimited, unauthenticated
    var errorDescription: String? {
        switch self {
        case .badMessage(let reason): "Bad editor message: \(reason)"
        case .replay: "Replayed or out-of-order editor message"
        case .stale: "Stale editor message"
        case .tooLarge: "Editor message too large"
        case .rateLimited: "Editor sent too many messages"
        case .unauthenticated: "Editor not authenticated"
        }
    }
}

/// A paired editor (the key never leaves the Keychain except into memory for one session).
nonisolated struct TrustedEditor: Codable, Equatable, Identifiable, Sendable {
    var deviceID: String
    var name: String
    var key: Data
    var pairedAt: Date
    var expiresAt: Date
    var id: String { deviceID }
}

@MainActor protocol EditorTrustStore: AnyObject {
    func all() -> [TrustedEditor]
    func save(_ editor: TrustedEditor)
    func remove(_ deviceID: String)
}

@MainActor final class MemoryTrustStore: EditorTrustStore {
    private var editors: [String: TrustedEditor] = [:]
    func all() -> [TrustedEditor] { Array(editors.values) }
    func save(_ editor: TrustedEditor) { editors[editor.deviceID] = editor }
    func remove(_ deviceID: String) { editors[deviceID] = nil }
}

/// Trusted editors in the Keychain (this device only, available after first unlock).
@MainActor final class KeychainTrustStore: EditorTrustStore {
    private let service = "com.derrancap.RayNeoInterviewCompanion.editors"
    private let account = "trusted"

    func all() -> [TrustedEditor] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return [] }
        return (try? JSONDecoder().decode([TrustedEditor].self, from: data)) ?? []
    }

    func save(_ editor: TrustedEditor) { write(all().filter { $0.deviceID != editor.deviceID } + [editor]) }
    func remove(_ deviceID: String) { write(all().filter { $0.deviceID != deviceID }) }

    private func write(_ editors: [TrustedEditor]) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !editors.isEmpty, let data = try? JSONEncoder().encode(editors) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Handshake messages (plaintext; they carry only public keys, nonces and HMAC proofs).
nonisolated struct EditorHandshake: Codable, Equatable, Sendable {
    var type: String
    var v: Int?
    var serverKey: String?
    var clientKey: String?
    var nonce: String?
    var mode: String?
    var deviceID: String?
    var name: String?
    var mac: String?
    var reason: String?
    /// Bonjour name of this iPhone, so the editor can find it again after a network change.
    var service: String?
}

/// Encrypted frame: sequence number and ChaCha20-Poly1305 box (ciphertext + tag).
nonisolated struct EditorEnvelope: Codable, Equatable, Sendable {
    var seq: Int
    var box: String
}

/// One server-side connection: handshake, then the encrypted channel. Pure (clock and keys injected).
nonisolated struct EditorServerSession: Sendable {
    enum Outcome: Equatable, Sendable {
        case paired(TrustedEditor)
        case resumed(String)
        case rejected(String)
    }

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let nonce: Data
    /// Active one-time pairing code, if pairing is open.
    let pairingCode: String?
    var service: String?
    private(set) var keys: EditorCrypto.SessionKeys?
    private(set) var deviceID: String?
    private(set) var sent = 0
    private(set) var received = 0

    init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
         pairingCode: String?) {
        self.privateKey = privateKey
        self.nonce = nonce
        self.pairingCode = pairingCode
    }

    var authenticated: Bool { keys != nil }

    var hello: EditorHandshake {
        EditorHandshake(type: "hello", v: EditorCrypto.version, serverKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
                        nonce: nonce.base64EncodedString(), mode: pairingCode == nil ? "resume" : "pair", service: service)
    }

    /// Verifies the client's pair or resume message. Returns the reply to send and the outcome.
    mutating func handshake(_ message: EditorHandshake, trusted: [TrustedEditor], now: Date) -> (reply: EditorHandshake, outcome: Outcome) {
        func reject(_ reason: String) -> (EditorHandshake, Outcome) { (EditorHandshake(type: "rejected", reason: reason), .rejected(reason)) }
        guard message.v == EditorCrypto.version, let deviceID = message.deviceID, !deviceID.isEmpty, deviceID.count <= 64,
              let clientRaw = message.clientKey.flatMap({ Data(base64Encoded: $0) }),
              let clientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientRaw),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: clientKey) else { return reject("malformed handshake") }
        let transcript = EditorCrypto.transcript(serverKey: privateKey.publicKey.rawRepresentation, clientKey: clientRaw, nonce: nonce, deviceID: deviceID)
        switch message.type {
        case "pair":
            guard let pairingCode else { return reject("pairing is not open on the iPhone") }
            let codeHash = Data(SHA256.hash(data: Data(EditorCrypto.normalizeCode(pairingCode).utf8)))
            let keys = EditorCrypto.deriveKeys(shared: shared, nonce: nonce, secret: codeHash, mode: "pair")
            guard EditorCrypto.verify(message.mac, key: keys.auth, label: "client", transcript: transcript) else { return reject("wrong pairing code") }
            self.keys = keys
            self.deviceID = deviceID
            let editor = TrustedEditor(deviceID: deviceID, name: String((message.name ?? "Editor").prefix(64)),
                                       key: EditorCrypto.trustKey(shared: shared, nonce: nonce, codeHash: codeHash),
                                       pairedAt: now, expiresAt: now.addingTimeInterval(EditorCrypto.trustLifetime))
            return (EditorHandshake(type: "paired", mac: EditorCrypto.mac(keys.auth, "server", transcript).base64EncodedString()), .paired(editor))
        case "resume":
            guard let editor = trusted.first(where: { $0.deviceID == deviceID }) else { return reject("not paired (forgotten or never paired)") }
            guard editor.expiresAt > now else { return reject("pairing expired; pair again") }
            let keys = EditorCrypto.deriveKeys(shared: shared, nonce: nonce, secret: editor.key, mode: "session")
            guard EditorCrypto.verify(message.mac, key: keys.auth, label: "client", transcript: transcript) else { return reject("authentication failed") }
            self.keys = keys
            self.deviceID = deviceID
            return (EditorHandshake(type: "resumed", mac: EditorCrypto.mac(keys.auth, "server", transcript).base64EncodedString()), .resumed(deviceID))
        default:
            return reject("unexpected handshake")
        }
    }

    /// Encrypts one message body (a JSON object) with the server-to-client key; `ts` is added.
    mutating func seal(_ body: [String: Any], now: Date) throws -> EditorEnvelope {
        guard let keys else { throw EditorLinkError.unauthenticated }
        var body = body
        body["ts"] = Int(now.timeIntervalSince1970 * 1000)
        sent += 1
        let plain = try JSONSerialization.data(withJSONObject: body)
        return EditorEnvelope(seq: sent, box: try EditorCrypto.seal(plain, key: keys.s2c, seq: sent, direction: "s2c").base64EncodedString())
    }

    /// Decrypts one client message: strictly the next sequence number, authentic, recent and bounded.
    mutating func open(_ envelope: EditorEnvelope, now: Date) throws -> EditorEvent {
        guard let keys else { throw EditorLinkError.unauthenticated }
        guard envelope.seq == received + 1 else { throw EditorLinkError.replay }
        guard let box = Data(base64Encoded: envelope.box), box.count <= EditorCrypto.maxLine else { throw EditorLinkError.tooLarge }
        let plain: Data
        do { plain = try EditorCrypto.open(box, key: keys.c2s, seq: envelope.seq, direction: "c2s") } catch { throw EditorLinkError.badMessage("authentication tag") }
        let event = try JSONDecoder().decode(EditorEvent.self, from: plain)
        guard let ts = event.ts, abs(now.timeIntervalSince1970 - Double(ts) / 1000) <= EditorCrypto.maxSkew else { throw EditorLinkError.stale }
        received = envelope.seq
        return event
    }
}

/// Messages from the editor (decrypted). Metadata by default; `code` only for an explicit request.
nonisolated struct EditorEvent: Codable, Equatable, Sendable {
    struct Diagnostic: Codable, Equatable, Sendable {
        var message: String
        var severity: String
        var line: Int?
        var source: String?
        var code: String?
    }
    struct TaskResult: Codable, Equatable, Sendable {
        var name: String
        var kind: String
        var exitCode: Int?
    }

    var type: String
    var ts: Int?
    var id: Int?
    var file: String?
    var language: String?
    var line: Int?
    var column: Int?
    var symbol: String?
    var selectionLines: Int?
    var blockID: String?
    var present: [Bool]?
    var errors: Int?
    var warnings: Int?
    var stable: Bool?
    var diagnostics: [Diagnostic]?
    var task: TaskResult?
    var code: String?
    var enabled: Bool?
}

/// Token bucket: `rate` messages per second with a burst allowance.
nonisolated struct EditorRateLimiter: Sendable {
    var rate = 20.0
    var burst = 40.0
    private var tokens = 40.0
    private var last: Date?

    mutating func allow(at now: Date) -> Bool {
        if let last { tokens = min(burst, tokens + now.timeIntervalSince(last) * rate) }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

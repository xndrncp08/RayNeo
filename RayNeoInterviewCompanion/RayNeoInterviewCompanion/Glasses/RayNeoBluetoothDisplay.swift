import CoreBluetooth
import Foundation
import UIKit

/// Side effects of the RayNeo link. CoreBluetooth in the app, a fake in tests.
@MainActor protocol RayNeoLinkIO: AnyObject {
    var owner: RayNeoBluetoothDisplay? { get set }
    /// Power on if needed, then attach to a system-connected or scanned RayNeo iO.
    func start()
    /// Stop scanning and drop the link. Later callbacks for the old link are not delivered.
    func cancel()
    func readPairInfo()
    func subscribe()
    func write(_ frame: Data)
}

enum SessionAcknowledgement: Equatable, Sendable {
    case none, pending, confirmed, unconfirmed
    case rejected(Int)
    case closedByGlasses(String)

    var label: String {
        switch self {
        case .none: "—"
        case .pending: "Waiting for acknowledgement"
        case .confirmed: "Confirmed by glasses"
        case .unconfirmed: "No acknowledgement (timed out)"
        case .rejected(let code): "Rejected (code \(code))"
        case .closedByGlasses(let reason): "Closed by glasses (\(reason))"
        }
    }
}

/// EXPERIMENTAL RayNeo iO display over BLE, ported from OpenRayneo (Apache-2.0).
/// scan → connect → discover → read pair info → subscribe → device info (cmd 17) → authenticate (cmd 24/25)
/// → foreground visibility → display session (0x13 caption or 0x17 prompt) → wait for acknowledgement.
/// A successful write means "submitted", never "visible".
@MainActor @Observable final class RayNeoBluetoothDisplay: GlassesDisplay {
    let name = "RayNeo iO (BLE, experimental)"
    let isSimulated = false
    private(set) var connectionState: GlassesConnectionState = .disconnected {
        didSet {
            guard connectionState != oldValue else { return }
            log("State: \(oldValue.label) → \(connectionState.label)")
            onStateChange?(connectionState)
        }
    }
    @ObservationIgnored var onStateChange: ((GlassesConnectionState) -> Void)?

    // Configuration
    var sessionMode: DisplaySessionMode = .caption
    /// Caption compatibility mode: the iO-E081 displayed caption text although it never sent the
    /// type-8 acknowledgement (user-verified 2026-11-20). Applies to caption sessions only.
    var allowUnconfirmedSend = false {
        didSet {
            // Let the presenter re-evaluate (e.g. restore the current answer) without a state change.
            if allowUnconfirmedSend != oldValue, connectionState == .sessionUnconfirmed { onStateChange?(connectionState) }
        }
    }
    var language = "en-US"
    /// Caption config font_size for the next session start (2 = verified default).
    var captionFontSize = 2
    /// Caption text status: true = final (1, verified), false = in progress (0, experimental).
    var captionFinalStatus = true
    /// Seconds to wait for a session-start acknowledgement before reporting the session unconfirmed.
    var sessionAckWait = 8.0

    // Diagnostics snapshot
    private(set) var deviceName: String?
    private(set) var deviceIdentifier: String?
    private(set) var services: [String] = []
    private(set) var characteristics: [String] = []
    private(set) var authenticated = false
    private(set) var sessionID: String?
    private(set) var activeSessionMode: DisplaySessionMode?
    private(set) var sessionAck: SessionAcknowledgement = .none
    private(set) var lastTransmitted: String?
    private(set) var lastReceived: String?
    private(set) var lastError: String?
    private(set) var reconnectAttempts = 0
    private(set) var audioFramesReceived = 0

    static let maxReconnectAttempts = 5
    static let timeouts: [String: Double] = ["scan": 20, "connect": 15, "discover": 10, "authenticate": 10, "session": 8]

    @ObservationIgnored private let io: any RayNeoLinkIO
    @ObservationIgnored private let schedule: @MainActor (Double, @escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timerToken: UUID?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var classicAddress = Data()
    @ObservationIgnored private var deviceID = Data()
    @ObservationIgnored private var sequence: UInt16 = 0
    @ObservationIgnored private var receiveBuffer = Data()

    private static let authenticatedBeforeKey = "rayneo.authenticatedBefore"
    private static let localIDKey = "rayneo.localDeviceID"

    init(io: (any RayNeoLinkIO)? = nil, defaults: UserDefaults = .standard,
         schedule: @escaping @MainActor (Double, @escaping @MainActor () -> Void) -> Void = RayNeoBluetoothDisplay.sleepThen) {
        self.io = io ?? CoreBluetoothLinkIO()
        self.defaults = defaults
        self.schedule = schedule
        self.io.owner = self
    }

    static func sleepThen(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    var isReadyToSend: Bool {
        connectionState == .ready || (connectionState == .sessionUnconfirmed && allowUnconfirmedSend && activeSessionMode == .caption)
    }

    var sendBlockedReason: String? {
        guard !isReadyToSend else { return nil }
        switch connectionState {
        case .sessionUnconfirmed where activeSessionMode == .caption:
            return "caption session never acknowledged and Caption compatibility mode is OFF"
        case .sessionUnconfirmed:
            return "prompt sessions require an acknowledgement"
        default:
            return connectionState.label
        }
    }

    var diagnosticSummary: String {
        "state \(connectionState.label); session \(activeSessionMode?.rawValue ?? "none") sid \(sessionID.map { String($0.prefix(8)) } ?? "none"); ack \(sessionAck.label); compatibility mode \(allowUnconfirmedSend ? "on" : "off")"
    }

    // MARK: Public controls

    /// Idempotent: never interrupts an attempt in progress or an authenticated link.
    func connect() {
        guard !connectionState.isInProgress, !connectionState.isAuthenticatedLink else {
            return log("connect() ignored: \(connectionState.label)")
        }
        log("connect() requested")
        wanted = true
        reconnectAttempts = 0
        beginAttempt()
    }

    /// Closes the display session (giving the close frame time to leave), then drops the link.
    func disconnect() {
        log("disconnect() requested")
        wanted = false
        let hadLink = connectionState.isAuthenticatedLink
        closeSession(reason: "disconnect")
        generation += 1 // invalidates timers and pending reconnects
        timerToken = nil
        resetLink()
        connectionState = .disconnected
        let closing = generation
        if hadLink {
            schedule(0.4) { [weak self] in
                guard let self, self.generation == closing else { return }
                self.io.cancel()
            }
        } else {
            io.cancel()
        }
    }

    /// Opens (or re-opens) a display session on an authenticated link. Duplicate requests are ignored.
    func startDisplaySession() {
        guard connectionState.isAuthenticatedLink else { return log("Start session ignored: \(connectionState.label)") }
        guard connectionState != .startingSession else { return log("Start session ignored: already waiting for acknowledgement") }
        // The glasses refuse a new session while an old one is open, so close ours first.
        closeSession(reason: "replacing session")
        let sid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        sessionID = sid
        activeSessionMode = sessionMode
        sessionAck = .pending
        connectionState = .startingSession
        switch sessionMode {
        case .caption:
            transmit(business: RayNeoProtocol.captionBusiness, type: 7, json: RayNeoProtocol.captionStartBody(sid: sid, fontSize: captionFontSize),
                     label: "0x13 type 7 (start caption session, temporary display config, font_size \(captionFontSize)) sid \(sid.prefix(8))")
        case .prompt:
            transmit(business: RayNeoProtocol.promptBusiness, type: 1, json: RayNeoProtocol.promptStartBody(sid: sid, language: language),
                     label: "0x17 type 1 (start prompt session, mode \"conversation\", \(language)) sid \(sid.prefix(8))")
        }
        arm("session", seconds: sessionAckWait) { [weak self] in
            guard let self, self.sessionID == sid, self.connectionState == .startingSession else { return }
            self.sessionAck = .unconfirmed
            self.log("No session acknowledgement within \(self.sessionAckWait) s: session UNCONFIRMED (sending blocked unless allowed)")
            self.connectionState = .sessionUnconfirmed
        }
    }

    /// Called when there is new text but no session: reopens a session the GLASSES closed, once per call.
    /// Never runs on a timer, so a glasses-side close cannot cause a restart loop.
    func reopenSessionIfClosed() {
        guard connectionState == .authenticated, case .closedByGlasses = sessionAck else { return }
        log("New text to show and the glasses had closed the session: reopening once")
        startDisplaySession()
    }

    func show(_ text: String) async throws {
        guard isReadyToSend, let sid = sessionID, let mode = activeSessionMode else { throw GlassesError.notReady }
        let unconfirmed = connectionState == .sessionUnconfirmed ? " [EXPERIMENTAL: session unconfirmed]" : ""
        switch mode {
        case .caption:
            transmit(business: RayNeoProtocol.captionBusiness, type: 5, json: RayNeoProtocol.captionTextBody(sid: sid, text: text, final: captionFinalStatus),
                     label: "0x13 type 5 (caption text, \(captionFinalStatus ? "final" : "in progress"), \(text.count) chars) sid \(sid.prefix(8))\(unconfirmed)")
        case .prompt:
            transmit(business: RayNeoProtocol.promptBusiness, type: 5, json: RayNeoProtocol.promptTextBody(sid: sid, text: text),
                     label: "0x17 type 5 (prompt text, \(text.count) chars) sid \(sid.prefix(8))\(unconfirmed)")
        }
    }

    func restartSession() {
        guard connectionState.isAuthenticatedLink else { return log("Session restart skipped: \(connectionState.label)") }
        log("Restarting the display session (close, then start)")
        startDisplaySession() // closes the current session first
    }

    /// Replacement Lab: one caption with an explicit status, on the current session, logged without its
    /// text unless `logText` is set (test-only).
    func sendLabCaption(_ text: String, final: Bool, logText: Bool) throws -> String {
        guard connectionState == .ready || connectionState == .sessionUnconfirmed, let sid = sessionID, activeSessionMode == .caption else {
            throw GlassesError.notReady
        }
        transmit(business: RayNeoProtocol.captionBusiness, type: 5, json: RayNeoProtocol.captionTextBody(sid: sid, text: text, final: final),
                 label: "LAB 0x13 type 5 status \(final ? 1 : 0) (\(final ? "final" : "in progress")), \(text.count) chars, \(text.filter(\.isNewline).count) line breaks, sid \(sid.prefix(8))\(logText ? ", text: \(text)" : "")")
        return String(sid.prefix(8))
    }

    func clear() async throws {
        guard isReadyToSend, let sid = sessionID, let mode = activeSessionMode else { throw GlassesError.notReady }
        let business = mode == .caption ? RayNeoProtocol.captionBusiness : RayNeoProtocol.promptBusiness
        transmit(business: business, type: 5, json: RayNeoProtocol.clearBody(sid: sid, prompt: mode == .prompt),
                 label: "\(String(format: "0x%02X", business)) type 5 (clear: full-width blank in source and translation, final) sid \(sid.prefix(8))")
    }

    /// Sends the fixed test text. Unconfirmed sessions require `allowUnconfirmed`.
    func sendTestCaption(_ text: String = "HELLO FROM IPHONE", allowUnconfirmed: Bool) async throws {
        let previous = allowUnconfirmedSend
        allowUnconfirmedSend = previous || allowUnconfirmed
        defer { allowUnconfirmedSend = previous }
        log("Test caption requested (\(text.count) chars, state: \(connectionState.label))")
        try await show(text)
    }

    // MARK: Attempt lifecycle

    private func beginAttempt() {
        generation += 1
        resetLink()
        connectionState = .scanning
        arm("scan") { [weak self] in self?.fail("No RayNeo iO found within \(Int(Self.timeouts["scan"]!)) s (glasses on and nearby?)") }
        io.start()
    }

    private func resetLink() {
        authenticated = false
        sessionID = nil
        activeSessionMode = nil
        sessionAck = .none
        receiveBuffer = Data()
        audioFramesReceived = 0
    }

    private func fail(_ reason: String) {
        log("Failure: \(reason)")
        lastError = reason
        generation += 1
        timerToken = nil
        resetLink()
        io.cancel()
        connectionState = .failed(reason)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard wanted else { return }
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            log("Giving up after \(reconnectAttempts) reconnect attempts; tap Connect to retry")
            return
        }
        reconnectAttempts += 1
        let delay = [2.0, 4, 8, 16, 30][min(reconnectAttempts - 1, 4)]
        let scheduled = generation
        log("Reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts) in \(Int(delay)) s")
        schedule(delay) { [weak self] in
            guard let self, self.wanted, self.generation == scheduled,
                  !self.connectionState.isInProgress, !self.connectionState.isAuthenticatedLink else { return }
            self.beginAttempt()
        }
    }

    /// One stage timer at a time; stale timers (older generation or replaced) do nothing.
    private func arm(_ stage: String, seconds: Double? = nil, _ onTimeout: @escaping @MainActor () -> Void) {
        let token = UUID(), armedGeneration = generation
        timerToken = token
        schedule(seconds ?? Self.timeouts[stage] ?? 10) { [weak self] in
            guard let self, self.timerToken == token, self.generation == armedGeneration else { return }
            self.timerToken = nil
            onTimeout()
        }
    }

    private func closeSession(reason: String) {
        guard let sid = sessionID, let mode = activeSessionMode, connectionState.isAuthenticatedLink else { return }
        switch mode {
        case .caption:
            transmit(business: RayNeoProtocol.captionBusiness, type: 3, json: RayNeoProtocol.captionStopBody(sid: sid),
                     label: "0x13 type 3 (close caption session, reason_code 10, \(reason)) sid \(sid.prefix(8))")
        case .prompt:
            transmit(business: RayNeoProtocol.promptBusiness, type: 3, json: RayNeoProtocol.promptStopBody(sid: sid),
                     label: "0x17 type 3 (close prompt session, reason_code 2, \(reason)) sid \(sid.prefix(8))")
        }
        sessionID = nil
        activeSessionMode = nil
        sessionAck = .none
    }

    // MARK: IO callbacks (called by CoreBluetoothLinkIO, or directly by tests)

    func ioCentralUnavailable(_ reason: String) {
        log("Bluetooth unavailable: \(reason)")
        generation += 1
        timerToken = nil
        connectionState = .unavailable(reason)
    }

    /// Bluetooth came back on: resume a wanted connection that was blocked by "unavailable".
    func ioPoweredOn() {
        guard wanted, case .unavailable = connectionState else { return }
        beginAttempt()
    }

    func ioFound(name: String, identifier: UUID, summary: String) {
        guard connectionState == .scanning else { return }
        deviceName = name
        deviceIdentifier = identifier.uuidString
        log("Found \(name): \(summary)")
        connectionState = .connecting
        arm("connect") { [weak self] in self?.fail("Connection timed out") }
    }

    func ioConnected(mtu: Int) {
        guard connectionState == .connecting else { return }
        log("Link connected; max write without response \(mtu) bytes")
        connectionState = .discovering
        arm("discover") { [weak self] in self?.fail("Service discovery / identity read timed out") }
    }

    func ioDiscovered(services: [String], characteristics: [String], complete: Bool) {
        guard connectionState == .discovering else { return }
        self.services = services
        self.characteristics = characteristics
        log("Services [\(services.joined(separator: ","))] characteristics [\(characteristics.joined(separator: ", "))]")
        guard complete else { return fail("B81D service or required characteristics missing") }
        io.readPairInfo()
    }

    func ioPairInfo(_ value: Data?) {
        guard connectionState == .discovering else { return }
        // Layout per OpenRayneo: [0..<6] classic address, [6] bond state, [7..<13] bound phone identity.
        guard let value, value.count >= 13 else { return fail("Pair info unreadable (\(value?.count ?? 0) bytes)") }
        let bytes = [UInt8](value)
        classicAddress = Data(bytes[0..<6])
        let bound = Data(bytes[7..<13])
        let useBound = !bound.allSatisfy { $0 == 0 }
        deviceID = useBound ? bound : localDeviceID
        log("Pair info read; bond state \(bytes[6]); using \(useBound ? "glasses-bound" : "app-generated") identity")
        io.subscribe()
    }

    func ioNotify(enabled: Bool, error: String?) {
        guard connectionState == .discovering else { return }
        log("Notifications on receive characteristic: \(enabled)\(error.map { " (\($0))" } ?? "")")
        guard enabled else { return fail("Could not subscribe to notifications") }
        connectionState = .authenticating
        arm("authenticate") { [weak self] in self?.fail("Authentication timed out") }
        sendDeviceInfo()
    }

    func ioReceived(_ data: Data) {
        receiveBuffer.append(data)
        for message in RayNeoProtocol.extractFrames(from: &receiveBuffer) { handle(message) }
    }

    func ioDisconnected(error: String?) {
        log("Link dropped by iOS/glasses: \(error ?? "no error")")
        lastError = error ?? "Link dropped"
        generation += 1
        timerToken = nil
        resetLink()
        connectionState = .disconnected
        scheduleReconnect()
    }

    func ioFailed(_ reason: String) {
        guard connectionState.isInProgress || connectionState.isAuthenticatedLink else { return }
        fail(reason)
    }

    // MARK: Protocol

    private func sendDeviceInfo() {
        let identity: UInt8 = defaults.bool(forKey: Self.authenticatedBeforeKey) ? 2 : 1
        sendPairing(command: 17, fields: [
            (16, Data([1])), (17, deviceID), (18, Data(UIDevice.current.name.utf8)), (19, Data([1])),
            (22, Data("iPhone".utf8)), (23, Data(UIDevice.current.model.utf8)), (27, Data([identity])),
        ])
    }

    private func handle(_ message: RayNeoProtocol.Message) {
        logReceived(message)
        if message.needsAck, let ack = try? RayNeoProtocol.acknowledgement(business: message.businessID, sequence: message.sequence) {
            io.write(ack)
        }
        if message.businessID == RayNeoProtocol.pairingBusiness {
            handlePairing(message)
        } else if message.businessID == RayNeoProtocol.captionBusiness || message.businessID == RayNeoProtocol.promptBusiness {
            handleSession(message)
        }
    }

    private func handlePairing(_ message: RayNeoProtocol.Message) {
        guard message.payload.first != 0x1E, let (command, body, tlvs) = RayNeoProtocol.pairingCommand(message.payload) else { return }
        switch command {
        case 17 where connectionState == .authenticating:
            guard tlvs[25] == nil else { return fail("Glasses requested account-bound ECDH authentication (not supported)") }
            let random = Data((0..<4).map { _ in UInt8.random(in: 0...255) })
            sendPairing(command: 24, fields: [(16, random), (17, RayNeoProtocol.authDigest(random: random, deviceID: deviceID, classicAddress: classicAddress))])
        case 25 where connectionState == .authenticating:
            guard let random = tlvs[16], random.count == 4, let proof = tlvs[17], proof.count == 32 else { return fail("Invalid authentication reply") }
            guard RayNeoProtocol.authDigest(random: random, deviceID: deviceID, classicAddress: classicAddress) == proof else {
                return fail("Glasses' authentication proof did not verify")
            }
            defaults.set(true, forKey: Self.authenticatedBeforeKey)
            timerToken = nil
            authenticated = true
            reconnectAttempts = 0
            log("Authenticated")
            connectionState = .authenticated
            if let frame = try? RayNeoProtocol.appVisibilityFrame(sequence: nextSequence(), foreground: true) {
                send(frame, label: "0x10 cmd 31 (app visibility: foreground)")
            }
            startDisplaySession()
        case 22, 23:
            log("Pairing status notification \(command): \(body.first.map(String.init) ?? "-")")
        default:
            break
        }
    }

    private func handleSession(_ message: RayNeoProtocol.Message) {
        guard let json = message.json, message.type != 4 else { return }
        let business = message.businessID == RayNeoProtocol.captionBusiness ? DisplaySessionMode.caption : .prompt
        guard let sid = sessionID, json["sid"] as? String == sid, business == activeSessionMode else {
            return log("Ignored \(String(format: "0x%02X", message.businessID)) type \(message.type.map(String.init) ?? "-") for another session (sid \((json["sid"] as? String)?.prefix(8) ?? "none"), ours \(sessionID?.prefix(8) ?? "none"))")
        }
        let ackType: UInt64 = business == .caption ? 8 : 2
        if message.type == ackType, connectionState == .startingSession || connectionState == .sessionUnconfirmed {
            timerToken = nil
            let code = (json["code"] as? NSNumber)?.intValue ?? -1
            if code == 1 {
                sessionAck = .confirmed
                reconnectAttempts = 0
                log("Display session CONFIRMED (code 1)")
                connectionState = .ready
            } else {
                // Keep the authenticated link: a rejection is not a transport failure.
                sessionAck = .rejected(code)
                lastError = "Session rejected (code \(code))"
                log("Display session REJECTED (code \(code)); link kept, no automatic retry")
                connectionState = .sessionRejected("code \(code)")
            }
        } else if message.type == 3 {
            handleSessionControl(json)
        }
    }

    /// Type 3 is a control message, not always a close. Reason codes per OpenRayneo DisplayController:
    /// 8/12 paused, 9/13 active again, 17 weak network, 1–7/10/11/14 closed, anything else ignored.
    private func handleSessionControl(_ json: [String: AnyHashable]) {
        guard let reason = (json["reason_code"] as? NSNumber)?.intValue else {
            return log("Type 3 without reason_code for our session: ignored")
        }
        switch reason {
        case 8, 12:
            log("Glasses PAUSED our display session (reason_code \(reason)); session kept, text held until resumed")
            connectionState = .sessionPaused("reason_code \(reason)")
        case 9, 13:
            guard case .sessionPaused = connectionState else { return log("Resume (reason_code \(reason)) while not paused: ignored") }
            log("Glasses RESUMED our display session (reason_code \(reason))")
            connectionState = sessionAck == .confirmed ? .ready : .sessionUnconfirmed
        case 17:
            log("Glasses reported a weak network (reason_code 17); session unchanged")
        case 1...7, 10, 11, 14:
            log("Glasses CLOSED our display session (reason_code \(reason)); reopened only when new text needs showing")
            sessionID = nil
            activeSessionMode = nil
            sessionAck = .closedByGlasses("reason_code \(reason)")
            connectionState = .authenticated
        default:
            log("Type 3 with unknown reason_code \(reason): session unchanged")
        }
    }

    // MARK: Writes and logging

    private func nextSequence() -> UInt16 { defer { sequence &+= 1 }; return sequence }

    private func transmit(business: UInt8, type: UInt64, json: [String: Any], label: String) {
        guard let frame = try? RayNeoProtocol.businessFrame(business: business, sequence: nextSequence(), type: type, json: json) else {
            return log("Could not encode \(label)")
        }
        send(frame, label: label)
    }

    private func sendPairing(command: UInt8, fields: [(UInt8, Data)]) {
        guard let frame = try? RayNeoProtocol.pairingFrame(sequence: nextSequence(), command: command, fields: fields) else { return }
        send(frame, label: "0x10 pairing cmd \(command) (TLV tags \(fields.map { String($0.0) }.joined(separator: ",")))")
    }

    private func send(_ frame: Data, label: String) {
        lastTransmitted = label
        DiagnosticLog.shared.record(.tx, "\(label), \(frame.count) bytes")
        io.write(frame)
    }

    private func log(_ message: String) {
        DiagnosticLog.shared.record(.ble, message)
    }

    /// Every inbound frame, summarised. Audio frames (0x13/0x17 type 4) are counted, not listed.
    private func logReceived(_ message: RayNeoProtocol.Message) {
        let id = String(format: "0x%02X", message.businessID)
        if [RayNeoProtocol.captionBusiness, RayNeoProtocol.promptBusiness].contains(message.businessID), message.type == 4 {
            audioFramesReceived += 1
            if audioFramesReceived == 1 || audioFramesReceived % 200 == 0 {
                DiagnosticLog.shared.record(.rx, "\(id) type 4 audio frames: \(audioFramesReceived) (content not stored)")
            }
            return
        }
        var summary = "\(id) seq \(message.sequence)\(message.needsAck ? " (ack requested)" : "")"
        if message.businessID == RayNeoProtocol.pairingBusiness {
            if let parsed = RayNeoProtocol.pairingCommand(message.payload) {
                summary += " pairing cmd \(parsed.command)" + (parsed.tlvs.isEmpty
                    ? " raw \(parsed.body.prefix(8).map { String(format: "%02X", $0) }.joined())"
                    : " TLV tags \(parsed.tlvs.keys.sorted().map(String.init).joined(separator: ","))")
            } else {
                summary += " raw \(message.payload.prefix(8).map { String(format: "%02X", $0) }.joined())"
            }
        } else {
            summary += " type \(message.type.map(String.init) ?? "-")"
            if let json = message.json {
                // Keys plus short values; text-bearing fields are reduced to their length.
                summary += " {" + json.keys.sorted().map { key in
                    if ["content", "text", "source_transcript", "target_translation", "query", "answer"].contains(key) {
                        return "\(key)=<\(json[key].map { "\($0)" }?.count ?? 0) chars>"
                    }
                    let value = json[key].map { "\($0)" } ?? "nil"
                    return "\(key)=\(value.count > 24 ? value.prefix(24) + "…" : Substring(value))"
                }.joined(separator: ", ") + "}"
            } else {
                summary += " (\(message.payload.count) bytes, no JSON)"
            }
        }
        lastReceived = summary
        DiagnosticLog.shared.record(.rx, summary)
    }

    private var localDeviceID: Data {
        // iOS cannot read its own Bluetooth address; the protocol only needs a stable 6-byte identity.
        if let saved = defaults.data(forKey: Self.localIDKey), saved.count == 6 { return saved }
        let fresh = Data((0..<6).map { _ in UInt8.random(in: 0...255) })
        defaults.set(fresh, forKey: Self.localIDKey)
        return fresh
    }
}

/// CoreBluetooth implementation of the link side effects. Delegate callbacks run on the main queue.
@MainActor final class CoreBluetoothLinkIO: NSObject, RayNeoLinkIO {
    weak var owner: RayNeoBluetoothDisplay?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var sendCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var pairInfoCharacteristic: CBCharacteristic?
    private var pendingWrites: [Data] = []
    private var startWhenPoweredOn = false

    private static let serviceUUID = CBUUID(string: RayNeoProtocol.serviceUUID)
    private static let sendUUID = CBUUID(string: RayNeoProtocol.sendUUID)
    private static let receiveUUID = CBUUID(string: RayNeoProtocol.receiveUUID)
    private static let pairInfoUUID = CBUUID(string: RayNeoProtocol.pairInfoUUID)

    func start() {
        cancel()
        guard let central else {
            startWhenPoweredOn = true
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
            return
        }
        guard central.state == .poweredOn else { startWhenPoweredOn = true; return }
        scanOrAttach(central)
    }

    func cancel() {
        startWhenPoweredOn = false
        central?.stopScan()
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        sendCharacteristic = nil; receiveCharacteristic = nil; pairInfoCharacteristic = nil
        pendingWrites = []
    }

    func readPairInfo() {
        guard let peripheral, let pairInfoCharacteristic else { return owner?.ioFailed("Pair info characteristic unavailable") ?? () }
        peripheral.readValue(for: pairInfoCharacteristic)
    }

    func subscribe() {
        guard let peripheral, let receiveCharacteristic else { return owner?.ioFailed("Receive characteristic unavailable") ?? () }
        peripheral.setNotifyValue(true, for: receiveCharacteristic)
    }

    func write(_ frame: Data) {
        guard let peripheral, peripheral.state == .connected, let sendCharacteristic else {
            return DiagnosticLog.shared.record(.tx, "BLE write DROPPED (\(frame.count) bytes): no connected link/characteristic")
        }
        let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        guard maximum > 0 else { return DiagnosticLog.shared.record(.tx, "BLE write DROPPED: write length unavailable") }
        for offset in stride(from: 0, to: frame.count, by: maximum) {
            pendingWrites.append(frame.subdata(in: offset..<min(offset + maximum, frame.count)))
        }
        let handed = drain(peripheral, sendCharacteristic)
        if !pendingWrites.isEmpty {
            DiagnosticLog.shared.record(.tx, "BLE write: \(handed) chunk(s) handed to iOS, \(pendingWrites.count) queued until the link is ready")
        }
    }

    /// Write-without-response has no per-packet completion; "handed to iOS" is the transport-level result.
    @discardableResult
    private func drain(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) -> Int {
        var handed = 0
        while !pendingWrites.isEmpty, peripheral.canSendWriteWithoutResponse {
            peripheral.writeValue(pendingWrites.removeFirst(), for: characteristic, type: .withoutResponse)
            handed += 1
        }
        return handed
    }

    private func scanOrAttach(_ central: CBCentralManager) {
        startWhenPoweredOn = false
        // The official app may already hold an LE link; iOS lets apps share it.
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            return attach(connected, summary: "already connected to iOS (possibly by the official RayNeo app)")
        }
        // OpenRayneo scans without a service filter and matches name or service: the glasses may not advertise B81D.
        central.scanForPeripherals(withServices: nil)
    }

    private func attach(_ target: CBPeripheral, summary: String) {
        central?.stopScan()
        peripheral = target
        target.delegate = self
        owner?.ioFound(name: target.name ?? "RayNeo iO", identifier: target.identifier, summary: summary)
        central?.connect(target)
    }
}

extension CoreBluetoothLinkIO: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DiagnosticLog.shared.record(.ble, "Central state \(central.state.rawValue) (5 = on), authorization \(CBManager.authorization.rawValue) (3 = allowed)")
        switch central.state {
        case .poweredOn:
            if startWhenPoweredOn { scanOrAttach(central) }
            owner?.ioPoweredOn()
        case .unauthorized: owner?.ioCentralUnavailable("Bluetooth permission denied (Settings › Privacy › Bluetooth)")
        case .unsupported: owner?.ioCentralUnavailable("Bluetooth LE unsupported")
        case .poweredOff: owner?.ioCentralUnavailable("Bluetooth is off")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        let isRayNeoMaker = maker.count >= 2 && maker[maker.startIndex] == 0x16 && maker[maker.startIndex + 1] == 0x57
        // Only RayNeo devices are logged or attached; other nearby devices are ignored.
        guard name.localizedCaseInsensitiveContains("RayNeo") || services.contains(Self.serviceUUID) || isRayNeoMaker else { return }
        attach(peripheral, summary: "RSSI \(RSSI), advertised services [\(services.map(\.uuidString).joined(separator: ","))], manufacturer prefix \(maker.prefix(3).map { String(format: "%02X", $0) }.joined())")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        owner?.ioConnected(mtu: peripheral.maximumWriteValueLength(for: .withoutResponse))
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        owner?.ioFailed("Connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        // cancel() clears `peripheral` first, so our own disconnects never reach the owner.
        guard peripheral === self.peripheral else { return }
        self.peripheral = nil
        owner?.ioDisconnected(error: error?.localizedDescription)
    }
}

extension CoreBluetoothLinkIO: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let found = peripheral.services?.map(\.uuid.uuidString) ?? []
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            return owner?.ioDiscovered(services: found, characteristics: [], complete: false) ?? ()
        }
        peripheral.discoverCharacteristics([Self.sendUUID, Self.receiveUUID, Self.pairInfoUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        let all = service.characteristics ?? []
        sendCharacteristic = all.first { $0.uuid == Self.sendUUID }
        receiveCharacteristic = all.first { $0.uuid == Self.receiveUUID }
        pairInfoCharacteristic = all.first { $0.uuid == Self.pairInfoUUID }
        owner?.ioDiscovered(services: peripheral.services?.map(\.uuid.uuidString) ?? [],
                            characteristics: all.map { "\($0.uuid.uuidString.prefix(8)) props \($0.properties.rawValue)" },
                            complete: sendCharacteristic != nil && receiveCharacteristic != nil && pairInfoCharacteristic != nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral else { return }
        if characteristic.uuid == Self.pairInfoUUID {
            owner?.ioPairInfo(error == nil ? characteristic.value : nil)
        } else if characteristic.uuid == Self.receiveUUID, let value = characteristic.value {
            owner?.ioReceived(value)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard peripheral === self.peripheral, characteristic.uuid == Self.receiveUUID else { return }
        owner?.ioNotify(enabled: characteristic.isNotifying, error: error?.localizedDescription)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === self.peripheral, let sendCharacteristic else { return }
        let handed = drain(peripheral, sendCharacteristic)
        if handed > 0 { DiagnosticLog.shared.record(.tx, "BLE write: \(handed) queued chunk(s) handed to iOS, \(pendingWrites.count) left") }
    }
}

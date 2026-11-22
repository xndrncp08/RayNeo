import SwiftUI

/// Hardware bring-up screen. Works without the microphone or AI pipeline.
struct RayNeoDiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var testResult: String?
    @State private var awaitingConfirmation = false
    private let log = DiagnosticLog.shared

    var body: some View {
        Form {
            if let ble = model.rayNeo {
                Section("Connection") {
                    row("State", ble.connectionState.label)
                    row("Device", ble.deviceName ?? "—")
                    row("Bluetooth identifier", ble.deviceIdentifier ?? "—")
                    row("Services", ble.services.isEmpty ? "—" : ble.services.joined(separator: ", "))
                    row("Characteristics", ble.characteristics.isEmpty ? "—" : ble.characteristics.joined(separator: "\n"))
                    row("Authenticated", ble.authenticated ? "Yes" : "No")
                    row("Reconnect attempts", "\(ble.reconnectAttempts)/\(RayNeoBluetoothDisplay.maxReconnectAttempts)")
                    row("Firmware version", "Not available (no verified read mechanism)")
                    HStack {
                        Button("Connect") { model.connectGlasses() }
                        Spacer()
                        Button("Disconnect", role: .destructive) { model.disconnectGlasses() }
                    }
                    .buttonStyle(.bordered)
                }
                Section {
                    Picker("Session type", selection: $model.settings.glassesSessionMode) {
                        ForEach(DisplaySessionMode.allCases) { Text($0.label).tag($0) }
                    }
                    row("Active session", ble.sessionID.map { "\(ble.activeSessionMode?.rawValue ?? "?") · \($0.prefix(8))" } ?? "—")
                    row("Acknowledgement", ble.sessionAck.label)
                    Button("Start display session") { ble.startDisplaySession() }
                        .disabled(!ble.connectionState.isAuthenticatedLink || ble.connectionState == .startingSession)
                } header: { Text("Display session") } footer: {
                    Text("Caption (0x13) is the default: it is the session type reported to work from an iPhone over CoreBluetooth. Changing the type applies to the next session start.")
                }
                Section {
                    Button("Send \"HELLO FROM IPHONE\"") { send(allowUnconfirmed: false) }
                        .disabled(ble.connectionState != .ready)
                    if ble.connectionState == .sessionUnconfirmed {
                        Button("Send anyway on UNCONFIRMED session (experimental)", role: .destructive) { send(allowUnconfirmed: true) }
                    }
                    if let testResult { Text(testResult).font(.callout) }
                    if awaitingConfirmation {
                        Text("Do you see HELLO FROM IPHONE on the glasses?").font(.callout.weight(.semibold))
                        HStack {
                            Button("Yes, visible") { confirm(true) }.buttonStyle(.borderedProminent)
                            Button("Not visible") { confirm(false) }.buttonStyle(.bordered)
                        }
                    }
                } header: { Text("Test caption") } footer: {
                    Text("A successful Bluetooth write does not prove the text appeared. Wear the glasses (display on) and record what you see; your answer is written to the log.")
                }
                Section {
                    Toggle("Caption compatibility mode (send without acknowledgement)", isOn: $model.settings.allowUnconfirmedGlassesSend)
                    row("Answers forwarded automatically", ble.isReadyToSend ? "Yes" : "No — \(ble.connectionState.label)")
                    row("Last delivery", model.presenter.deliveryStatus)
                } header: { Text("AI answer forwarding") } footer: {
                    Text("Verified on an iO-E081: caption text appeared although the session was never acknowledged. Caption sessions only.")
                }
                Section {
                    NavigationLink("Caption calibration") { CaptionCalibrationView(model: model) }
                }
                Section("Last messages") {
                    row("Last sent", ble.lastTransmitted ?? "—")
                    row("Last received", ble.lastReceived ?? "—")
                    row("Last error", ble.lastError ?? "—")
                    row("Audio frames received", "\(ble.audioFramesReceived) (not stored)")
                }
            } else {
                Section {
                    Text("The glasses display is set to the in-app simulator, so no Bluetooth traffic is sent.")
                    Button("Use RayNeo iO (experimental BLE)") { model.settings.glassesTarget = .rayNeoExperimental }
                }
            }
            Section("Recent events (\(log.entries.count))") {
                HStack {
                    ShareLink("Export diagnostics", item: exportText)
                    Spacer()
                    Button("Clear", role: .destructive) { log.clear() }
                }
                .buttonStyle(.borderless)
                ForEach(log.entries.suffix(60).reversed()) { entry in
                    Text(entry.line).font(.caption2.monospaced()).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("RayNeo Diagnostics")
    }

    private var exportText: String {
        var header = ["RayPrompt diagnostics", "Exported: \(Date().formatted(.iso8601))"]
        if let ble = model.rayNeo {
            header += ["State: \(ble.connectionState.label)", "Device: \(ble.deviceName ?? "-")",
                       "Session mode setting: \(model.settings.glassesSessionMode.rawValue)",
                       "Active session: \(ble.activeSessionMode?.rawValue ?? "-") \(ble.sessionID?.prefix(8) ?? "-")",
                       "Acknowledgement: \(ble.sessionAck.label)", "Last error: \(ble.lastError ?? "-")"]
        }
        return (header + ["", log.text]).joined(separator: "\n")
    }

    private func send(allowUnconfirmed: Bool) {
        Task {
            testResult = await model.sendTestCaption(allowUnconfirmed: allowUnconfirmed)
            awaitingConfirmation = testResult?.hasPrefix("Written") == true
        }
    }

    private func confirm(_ visible: Bool) {
        model.recordVisualConfirmation(visible: visible)
        awaitingConfirmation = false
        testResult = visible ? "Recorded: visible on glasses." : "Recorded: not visible. Export the diagnostics and share them."
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing).font(.callout) }
    }
}

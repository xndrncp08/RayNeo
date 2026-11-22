import AVFoundation
import Foundation

enum AudioEvent: Equatable, Sendable {
    case interrupted
    case resumed
    case routeChanged(String)
    case failed(String)
}

struct AudioInputOption: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
}

/// Called on the audio thread with a buffer already converted to the recognizer format.
typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioFramePosition) -> Void

@MainActor protocol AudioCapturing: AnyObject {
    var isRunning: Bool { get }
    var inputName: String { get }
    var onEvent: ((AudioEvent) -> Void)? { get set }
    func availableInputs() -> [AudioInputOption]
    func start(format: AVAudioFormat, preferredInputUID: String?, handler: @escaping AudioBufferHandler) throws
    func stop()
}

/// Continuous microphone capture with AVAudioEngine. Prefers the built-in iPhone microphone and
/// uses the `.record` category without Bluetooth options, so a Bluetooth headset (or the glasses'
/// hands-free profile) never silently becomes the input.
@MainActor final class AudioCaptureService: AudioCapturing {
    private(set) var isRunning = false
    private(set) var inputName = "—"
    var onEvent: ((AudioEvent) -> Void)?

    private let engine = AVAudioEngine()
    private var tap: AudioTapProcessor?
    private var format: AVAudioFormat?
    private var preferredUID: String?
    private var handler: AudioBufferHandler?
    private var observers: [NSObjectProtocol] = []
    private var interrupted = false

    init() { observe() }

    func availableInputs() -> [AudioInputOption] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).map { AudioInputOption(id: $0.uid, name: $0.portName) }
    }

    func start(format: AVAudioFormat, preferredInputUID: String?, handler: @escaping AudioBufferHandler) throws {
        self.format = format
        self.preferredUID = preferredInputUID
        self.handler = handler
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)
        try selectInput()
        try startEngine()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap = nil
        handler = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func selectInput() throws {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.availableInputs ?? []
        let chosen = inputs.first { $0.uid == preferredUID } ?? inputs.first { $0.portType == .builtInMic }
        if let chosen { try session.setPreferredInput(chosen) }
        updateInputName()
    }

    private func updateInputName() {
        inputName = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "No input"
    }

    private func startEngine() throws {
        guard let format, let handler else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioCaptureError.noInput }
        guard let processor = AudioTapProcessor(input: inputFormat, output: format, handler: handler, startFrame: tap?.framePosition ?? 0) else {
            throw AudioCaptureError.converter
        }
        tap = processor
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: AudioTapProcessor.block(processor))
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    private func restart() {
        guard handler != nil, !interrupted else { return }
        engine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try selectInput()
            try startEngine()
            onEvent?(.resumed)
        } catch {
            isRunning = false
            onEvent?(.failed(error.localizedDescription))
        }
    }

    private func observe() {
        // Observer blocks are @Sendable. Extract Sendable values, then hop explicitly to the main actor.
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in self?.handleInterruption(type) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.handleRouteChange() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard handler != nil, let type else { return }
        if type == .began {
            interrupted = true
            isRunning = false
            onEvent?(.interrupted)
        } else {
            interrupted = false
            // Resume even without .shouldResume: the user explicitly started this session.
            restart()
        }
    }

    private func handleRouteChange() {
        let previous = inputName
        if handler != nil { try? selectInput() } else { updateInputName() }
        if inputName != previous { onEvent?(.routeChanged(inputName)) }
    }
}

enum AudioCaptureError: LocalizedError {
    case noInput, converter
    var errorDescription: String? {
        switch self {
        case .noInput: "No microphone input is available"
        case .converter: "Could not convert microphone audio to the recognizer format"
        }
    }
}

/// Runs on the real-time audio thread: converts and forwards, never touches the main actor.
nonisolated final class AudioTapProcessor: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let handler: AudioBufferHandler
    // Only mutated on the single audio thread that delivers tap callbacks.
    private(set) var framePosition: AVAudioFramePosition

    init?(input: AVAudioFormat, output: AVAudioFormat, handler: @escaping AudioBufferHandler, startFrame: AVAudioFramePosition) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.output = output
        self.handler = handler
        self.framePosition = startFrame
    }

    static func block(_ processor: AudioTapProcessor) -> AVAudioNodeTapBlock {
        { buffer, _ in processor.process(buffer) }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        handler(converted, framePosition)
        framePosition += AVAudioFramePosition(converted.frameLength)
    }
}

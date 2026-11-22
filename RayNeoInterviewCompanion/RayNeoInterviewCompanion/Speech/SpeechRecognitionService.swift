import AVFoundation
import CoreMedia
import Foundation
import Speech
import Synchronization

enum SpeechEvent: Equatable, Sendable {
    case partial(String)
    case final(String, start: Double, end: Double)
    case failed(String)
}

@MainActor protocol SpeechRecognizing: AnyObject, Sendable {
    var engineName: String { get }
    /// Installs assets if needed and returns the audio format the recognizer wants.
    func prepare(locale: Locale) async throws -> AVAudioFormat
    func start(onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws
    /// Thread-safe; called from the audio thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition)
    func stop() async
    /// Custom words (project names) the recognizer should expect. Applied at the next start.
    func setVocabulary(_ words: [String])
}

extension SpeechRecognizing {
    func setVocabulary(_ words: [String]) {}
}

enum SpeechError: LocalizedError {
    case unsupportedLocale(String), unavailable(String), notPrepared
    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): "Speech recognition does not support \(id) on this device"
        case .unavailable(let reason): "Speech recognition unavailable: \(reason)"
        case .notPrepared: "Speech recognizer was not prepared"
        }
    }
}

/// iOS 26 SpeechAnalyzer + SpeechTranscriber: on-device, long-form, no per-task time limit.
@MainActor final class AnalyzerSpeechRecognizer: SpeechRecognizing {
    let engineName = "SpeechAnalyzer (on-device)"
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var format: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private let input = Mutex<AsyncStream<AnalyzerInput>.Continuation?>(nil)
    private var vocabulary: [String] = []

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// SpeechAnalyzer `AnalysisContext.contextualStrings[.general]` (iOS 26 SDK), set before analysis starts.
    func setVocabulary(_ words: [String]) { vocabulary = words }

    func prepare(locale: Locale) async throws -> AVAudioFormat {
        guard SpeechTranscriber.isAvailable else { throw SpeechError.unavailable("SpeechTranscriber not available on this device") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError.unavailable("no compatible audio format")
        }
        self.transcriber = transcriber
        self.format = format
        return format
    }

    func start(onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws {
        guard let transcriber, let format else { throw SpeechError.notPrepared }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        input.withLock { $0 = continuation }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        resultsTask = Task { @MainActor in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        onEvent(.final(text, start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds))
                    } else {
                        onEvent(.partial(text))
                    }
                }
            } catch is CancellationError {
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
        let vocabulary = vocabulary
        analyzerTask = Task { @MainActor in
            do {
                if !vocabulary.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings = [.general: vocabulary]
                    try await analyzer.setContext(context)
                }
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) {
        let time = CMTime(value: frame, timescale: CMTimeScale(buffer.format.sampleRate))
        input.withLock { _ = $0?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time)) }
    }

    func stop() async {
        input.withLock { $0?.finish(); $0 = nil }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        analyzerTask?.cancel()
        analyzer = nil
    }
}

/// Fallback: SFSpeechRecognizer, on-device when supported. Restarts the task after each final
/// result and periodically, because a single recognition task is not meant to run indefinitely.
@MainActor final class LegacySpeechRecognizer: SpeechRecognizing {
    var engineName: String { onDevice ? "SFSpeechRecognizer (on-device)" : "SFSpeechRecognizer (server)" }
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var onEvent: (@MainActor (SpeechEvent) -> Void)?
    private var restartTimer: Task<Void, Never>?
    private var onDevice = false
    private var running = false
    private let request = RequestBox()
    private let latestFrame = Mutex<(AVAudioFramePosition, Double)>((0, 16_000))
    private var taskStartSeconds = 0.0
    private var vocabulary: [String] = []

    /// SFSpeechRecognitionRequest.contextualStrings, applied to every recognition task.
    func setVocabulary(_ words: [String]) { vocabulary = words }

    func prepare(locale: Locale) async throws -> AVAudioFormat {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw SpeechError.unsupportedLocale(locale.identifier) }
        guard recognizer.isAvailable else { throw SpeechError.unavailable("recognizer is not available right now") }
        self.recognizer = recognizer
        onDevice = recognizer.supportsOnDeviceRecognition
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    func start(onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws {
        guard recognizer != nil else { throw SpeechError.notPrepared }
        self.onEvent = onEvent
        running = true
        beginTask()
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer, at frame: AVAudioFramePosition) {
        latestFrame.withLock { $0 = (frame + AVAudioFramePosition(buffer.frameLength), buffer.format.sampleRate) }
        request.withLock { $0?.append(buffer) }
    }

    func stop() async {
        running = false
        restartTimer?.cancel()
        request.withLock { $0?.endAudio(); $0 = nil }
        task?.cancel()
        task = nil
    }

    private var nowSeconds: Double { latestFrame.withLock { Double($0.0) / $0.1 } }

    private func beginTask() {
        guard running, let recognizer else { return }
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.requiresOnDeviceRecognition = onDevice
        newRequest.addsPunctuation = true
        newRequest.contextualStrings = vocabulary
        request.withLock { $0?.endAudio(); $0 = newRequest }
        taskStartSeconds = nowSeconds
        let started = taskStartSeconds
        // Explicitly @Sendable: the handler runs on recognizer.queue, which must not be assumed to be main.
        task = recognizer.recognitionTask(with: newRequest) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true || result?.speechRecognitionMetadata != nil
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self, self.running, self.taskStartSeconds == started else { return }
                if let text, !text.isEmpty {
                    self.onEvent?(isFinal ? .final(text, start: started, end: self.nowSeconds) : .partial(text))
                }
                if isFinal || message != nil {
                    // "No speech detected" style errors are routine during silence; just restart.
                    self.beginTask()
                }
            }
        }
        restartTimer?.cancel()
        restartTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(55))
            guard let self, !Task.isCancelled, self.running, self.taskStartSeconds == started else { return }
            self.task?.finish()
        }
    }
}

/// SFSpeechAudioBufferRecognitionRequest is not Sendable; append is documented as callable from the
/// audio thread, so a plain lock around the current request is enough.
nonisolated final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func withLock(_ body: (inout SFSpeechAudioBufferRecognitionRequest?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&request)
    }
}

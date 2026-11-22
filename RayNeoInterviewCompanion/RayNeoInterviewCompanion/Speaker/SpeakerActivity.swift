import AVFoundation
import Foundation
import Synchronization

/// Per-buffer acoustic features on the capture timeline.
nonisolated struct VoiceFrame: Sendable {
    var time: Double
    var duration: Double
    var levelDB: Float
    var pitchHz: Float?
    /// Set when stored, against the noise floor at that moment.
    var voiced = false
}

/// Thread-safe rolling store of voice features (fed from the audio thread, read on main).
/// Speaker attribution is a heuristic on pitch + level against an optional wearer calibration;
/// a single iPhone microphone cannot reliably separate speakers, so this is one signal among
/// several (answer-echo similarity and the answer lock are the primary protections).
nonisolated final class SpeakerActivityService: Sendable {
    private let frames = Mutex<[VoiceFrame]>([])
    private let noiseFloor = Mutex<Float>(-60)
    static let retentionSeconds = 120.0

    func append(_ frame: VoiceFrame) {
        var frame = frame
        frame.voiced = isSpeech(frame)
        frames.withLock { frames in
            frames.append(frame)
            if let first = frames.first, frame.time - first.time > Self.retentionSeconds {
                frames.removeFirst(frames.firstIndex { frame.time - $0.time <= Self.retentionSeconds } ?? 0)
            }
        }
        // Fast-falling, very slow-rising (~30 s) noise floor, so sustained speech never becomes "noise".
        noiseFloor.withLock { floor in
            floor = frame.levelDB < floor ? frame.levelDB : floor + 0.003 * (frame.levelDB - floor)
        }
    }

    var latest: VoiceFrame? { frames.withLock { $0.last } }
    var frameCount: Int { frames.withLock { $0.count } }

    /// Voice activity: level clearly above the adaptive noise floor.
    func isSpeech(_ frame: VoiceFrame) -> Bool {
        frame.levelDB > max(noiseFloor.withLock { $0 } + 10, -55)
    }

    func reset() {
        frames.withLock { $0.removeAll() }
        noiseFloor.withLock { $0 = -60 }
    }

    func voicedStats(from start: Double, to end: Double) -> (pitch: Double?, level: Double?, seconds: Double) {
        let voiced = frames.withLock { frames in
            frames.filter { $0.time >= start - 0.2 && $0.time <= end + 0.2 && $0.voiced }
        }
        let pitches = voiced.compactMap(\.pitchHz).map(Double.init).sorted()
        let levels = voiced.map { Double($0.levelDB) }.sorted()
        return (pitches.isEmpty ? nil : pitches[pitches.count / 2],
                levels.isEmpty ? nil : levels[levels.count / 2],
                voiced.reduce(0) { $0 + $1.duration })
    }

    func evidence(start: Double, end: Double, profile: WearerProfile?, pitchTolerance: Double) -> SpeakerEvidence {
        let stats = voicedStats(from: start, to: end)
        var evidence = SpeakerEvidence(label: .unknown, medianPitchHz: stats.pitch, medianLevelDB: stats.level, voicedSeconds: stats.seconds, reason: "")
        guard let profile else { evidence.reason = "wearer not calibrated"; return evidence }
        guard let pitch = stats.pitch, stats.seconds >= 0.4 else { evidence.reason = "too little voiced audio"; return evidence }
        let semitones = abs(12 * log2(pitch / profile.medianPitchHz))
        let level = stats.level ?? -100
        if semitones <= pitchTolerance, level >= profile.medianLevelDB - 8 {
            evidence.label = .wearer
        } else if semitones > pitchTolerance * 1.6 {
            evidence.label = .interviewer
        }
        evidence.reason = String(format: "pitch %.0f Hz (%.1f st from wearer), level %.0f dB", pitch, semitones, level)
        return evidence
    }

    func makeProfile(from start: Double, to end: Double) -> WearerProfile? {
        let stats = voicedStats(from: start, to: end)
        guard let pitch = stats.pitch, let level = stats.level, stats.seconds >= 2 else { return nil }
        return WearerProfile(medianPitchHz: pitch, medianLevelDB: level, voicedSeconds: stats.seconds, createdAt: Date())
    }

    /// RMS level and autocorrelation pitch (70–400 Hz) of the first channel.
    static func analyze(_ buffer: AVAudioPCMBuffer, time: Double) -> VoiceFrame? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let count = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        var energy: Float = 0
        for index in 0..<count { energy += samples[index] * samples[index] }
        let rms = (energy / Float(count)).squareRoot()
        let level = 20 * log10(max(rms, 1e-7))
        return VoiceFrame(time: time, duration: Double(count) / rate, levelDB: level, pitchHz: level > -50 ? pitch(samples, count: count, rate: rate) : nil)
    }

    static func pitch(_ samples: UnsafePointer<Float>, count: Int, rate: Double) -> Float? {
        let step = max(1, Int(rate / 16_000))
        let n = count / step
        let minLag = Int(rate / Double(step) / 400), maxLag = Int(rate / Double(step) / 70)
        guard n > maxLag * 2 else { return nil }
        var zeroLag: Float = 0
        for index in 0..<n { zeroLag += samples[index * step] * samples[index * step] }
        guard zeroLag > 0 else { return nil }
        var bestLag = 0, best: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            for index in 0..<(n - lag) { sum += samples[index * step] * samples[(index + lag) * step] }
            if sum > best { best = sum; bestLag = lag }
        }
        // Require a clearly periodic signal.
        guard bestLag > 0, best / zeroLag > 0.3 else { return nil }
        return Float(rate / Double(step) / Double(bestLag))
    }
}

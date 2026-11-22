import Testing
@testable import RayNeoInterviewCompanion

@MainActor @Suite(.serialized) struct DiagnosticLogTests {
    @Test func logIsBounded() {
        let log = DiagnosticLog(capacity: 10)
        for index in 0..<50 { log.record(.ble, "event \(index)") }
        #expect(log.entries.count == 10)
        #expect(log.entries.last?.message == "event 49")
        #expect(log.text.contains("[ble] event 49"))
    }

    /// Documents the current coupling: the glasses link is requested only after the audio session is active.
    @Test func startSessionRecordsAudioActivationBeforeGlassesConnect() async {
        DiagnosticLog.shared.clear()
        let audio = MockAudio(), speech = MockSpeech(), ai = MockAIProvider(), glasses = MockGlassesDisplay()
        let model = AppModel(defaults: nil, audio: audio, speechFactory: { [speech] }, aiFactory: { _ in ai },
                             glassesFactory: { _ in glasses }, knowledge: KnowledgeBase(url: nil), permissions: { nil })
        await model.startSession()
        let messages = DiagnosticLog.shared.entries.map(\.message)
        let audioIndex = messages.firstIndex { $0.hasPrefix("Audio session active") }
        let connectIndex = messages.firstIndex { $0.hasPrefix("Requesting glasses connect()") }
        #expect(audioIndex != nil && connectIndex != nil)
        #expect((audioIndex ?? .max) < (connectIndex ?? .min))
        #expect(messages.first?.hasPrefix("Start Session: glasses target = Simulator") == true)
    }
}

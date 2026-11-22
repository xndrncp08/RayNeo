import AVFoundation
import Foundation
import Testing
@testable import RayNeoInterviewCompanion

@MainActor @Suite struct GlassesPresenterTests {
    // Cases 10–11: Bluetooth drops mid-session, answer is preserved and restored on reconnect.
    @Test func restoresCurrentPageAfterReconnect() async throws {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses)
        await presenter.present("Check the logs first. Then verify the token.")
        #expect(glasses.shown.count == 1)

        glasses.simulateDrop()
        #expect(presenter.connectionState == .disconnected)
        #expect(presenter.currentPage != nil) // answer is not cleared by a drop

        glasses.connect()
        try await Task.sleep(for: .milliseconds(50))
        #expect(glasses.shown.count == 2)
        #expect(glasses.shown.last == glasses.shown.first)
    }

    @Test func writeWhileDisconnectedReportsErrorWithoutLosingAnswer() async {
        let glasses = MockGlassesDisplay()
        let presenter = GlassesPresenter(display: glasses)
        await presenter.present("Answer text.")
        #expect(presenter.lastError != nil)
        #expect(presenter.currentPage == "Answer text.")
    }

    @Test func manualPaging() async {
        let glasses = MockGlassesDisplay()
        glasses.connect()
        let presenter = GlassesPresenter(display: glasses, layout: CaptionLayout(maxLines: 2, charactersPerLine: 20))
        await presenter.present("One two three four five. Six seven eight nine ten. Eleven twelve.")
        #expect(presenter.pages.count >= 2)
        await presenter.nextPage()
        #expect(presenter.pageIndex == 1)
        #expect(glasses.shown.last == presenter.pages[1])
        await presenter.previousPage()
        #expect(presenter.pageIndex == 0)
    }
}

@Suite struct RayNeoProtocolTests {
    @Test func crcMatchesXModemCheckValue() {
        #expect(RayNeoProtocol.crc16XModem(Data("123456789".utf8)) == 0x31C3)
    }

    @Test func frameLayoutAndRoundTrip() throws {
        let frame = try RayNeoProtocol.frame(business: 0x10, sequence: 0x0102, payload: Data([0x1F, 0x00, 0x01, 0x02]))
        #expect(Array(frame.prefix(8)) == [0xAA, 0x55, 0x00, 0x08, 0x01, 0x02, 0x00, 0x10])
        var buffer = Data([0x00, 0x13]) + frame + Data([0xAA]) // leading garbage + partial trailing byte
        let messages = RayNeoProtocol.extractFrames(from: &buffer)
        #expect(messages.count == 1)
        #expect(messages[0].businessID == 0x10)
        #expect(messages[0].sequence == 0x0102)
        #expect(messages[0].payload == Data([0x1F, 0x00, 0x01, 0x02]))
        #expect(buffer == Data([0xAA]))
    }

    @Test func fragmentedNotificationsReassemble() throws {
        let frame = try RayNeoProtocol.businessFrame(business: 0x17, sequence: 7, type: 2, json: ["sid": "abc", "code": 1])
        var buffer = Data()
        var messages: [RayNeoProtocol.Message] = []
        for chunk in stride(from: 0, to: frame.count, by: 5) {
            buffer.append(frame.subdata(in: chunk..<min(chunk + 5, frame.count)))
            messages += RayNeoProtocol.extractFrames(from: &buffer)
        }
        #expect(messages.count == 1)
        #expect(messages[0].type == 2)
        #expect(messages[0].json?["sid"] as? String == "abc")
        #expect((messages[0].json?["code"] as? NSNumber)?.intValue == 1)
    }

    @Test func corruptCRCIsRejected() throws {
        var frame = try RayNeoProtocol.frame(business: 0x17, sequence: 1, payload: Data([1, 2, 3]))
        frame[frame.count - 1] ^= 0xFF
        var buffer = frame
        #expect(RayNeoProtocol.extractFrames(from: &buffer).isEmpty)
    }

    @Test func pairingTLVRoundTripAndAuthDigest() throws {
        let random = Data([1, 2, 3, 4]), id = Data(repeating: 0xAB, count: 6), address = Data([0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
        let digest = RayNeoProtocol.authDigest(random: random, deviceID: id, classicAddress: address)
        #expect(digest.count == 32)
        let frame = try RayNeoProtocol.pairingFrame(sequence: 3, command: 24, fields: [(16, random), (17, digest)])
        var buffer = frame
        let message = try #require(RayNeoProtocol.extractFrames(from: &buffer).first)
        let parsed = try #require(RayNeoProtocol.pairingCommand(message.payload))
        #expect(parsed.command == 24)
        #expect(parsed.tlvs[16] == random)
        #expect(parsed.tlvs[17] == digest)
    }

    @Test func promptTextBodyMatchesOpenRayneoShape() throws {
        let frame = try RayNeoProtocol.businessFrame(business: 0x17, sequence: 9, type: 5, json: RayNeoProtocol.promptTextBody(sid: "s1", text: "Hello"))
        var buffer = frame
        let message = try #require(RayNeoProtocol.extractFrames(from: &buffer).first)
        #expect(message.type == 5)
        let content = message.json?["content"] as? [String: AnyHashable]
        #expect(content?["source_transcript"] as? String == "Hello")
        #expect((message.json?["mode"] as? NSNumber)?.intValue == 4)
        #expect((message.json?["status"] as? NSNumber)?.intValue == 1)
    }
}

@Suite struct SpeakerActivityTests {
    func tone(_ hz: Double, amplitude: Float = 0.3, rate: Double = 16_000, count: Int = 1600) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { buffer.floatChannelData![0][index] = amplitude * Float(sin(2 * .pi * hz * Double(index) / rate)) }
        return buffer
    }

    @Test func pitchEstimateIsCloseForVoiceRangeTones() throws {
        for hz in [110.0, 180.0, 240.0] {
            let frame = try #require(SpeakerActivityService.analyze(tone(hz), time: 0))
            let pitch = try #require(frame.pitchHz)
            #expect(abs(Double(pitch) - hz) / hz < 0.05, "expected \(hz), got \(pitch)")
        }
    }

    @Test func calibratedProfileSeparatesDistinctVoices() throws {
        let service = SpeakerActivityService()
        for step in 0..<40 { service.append(SpeakerActivityService.analyze(tone(120), time: Double(step) * 0.1)!) }
        let profile = try #require(service.makeProfile(from: 0, to: 4))
        for step in 40..<60 { service.append(SpeakerActivityService.analyze(tone(122), time: Double(step) * 0.1)!) }
        for step in 60..<80 { service.append(SpeakerActivityService.analyze(tone(220), time: Double(step) * 0.1)!) }
        #expect(service.evidence(start: 4.1, end: 5.9, profile: profile, pitchTolerance: 2.5).label == .wearer)
        #expect(service.evidence(start: 6.1, end: 7.9, profile: profile, pitchTolerance: 2.5).label == .interviewer)
        #expect(service.evidence(start: 6.1, end: 7.9, profile: nil, pitchTolerance: 2.5).label == .unknown)
    }
}

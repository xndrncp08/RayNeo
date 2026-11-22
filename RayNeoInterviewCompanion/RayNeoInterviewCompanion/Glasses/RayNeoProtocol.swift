// Portions derived from OpenRayneo (https://github.com/Tobi1chi/OpenRayneo),
// Copyright 2026 Tobi1chi, licensed under the Apache License 2.0:
// AA55 framing, CRC16-XMODEM, pairing TLVs, authentication digest, the app-visibility frame,
// the 0x13 caption bodies (DisplayController.applyCaptionDisplay / text / stop) and the 0x17 prompt bodies.
// iOS device-info tag values (0x13 = 1, 0x16 = "iPhone") follow Turbo-IO's recovered iOS exchange.

import CryptoKit
import Foundation

/// Wire constants and codec for RayNeo iO. Verified against real hardware by OpenRayneo on macOS
/// (Strix OS 1.0.5.x); NOT yet verified from iOS by this project. See RESEARCH.md.
nonisolated enum RayNeoProtocol {
    static let serviceUUID = "0000B81D-0000-1000-8000-00805F9B34FB"
    static let sendUUID = "EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9"
    static let receiveUUID = "7DB3E235-3608-41F3-A03C-955FCBD2EA4B"
    static let pairInfoUUID = "EA8B60C5-2BD3-49AB-9C31-9D38B1C5C5F9"
    static let authConstant = Data([0x07, 0x12, 0xC8, 0xAD, 0x27, 0x74, 0x41, 0x95, 0xDE, 0x5F, 0xA1, 0xEA, 0x6D, 0x02, 0x5F, 0xB8])

    static let pairingBusiness: UInt8 = 0x10
    static let captionBusiness: UInt8 = 0x13
    static let promptBusiness: UInt8 = 0x17

    struct Message: Equatable {
        var businessID: UInt8
        var sequence: UInt16
        var needsAck: Bool
        var payload: Data
        var type: UInt64?
        var json: [String: AnyHashable]?
    }

    enum CodecError: Error { case payloadTooLarge }

    // MARK: Framing

    static func frame(business: UInt8, sequence: UInt16, payload: Data, magic: UInt16 = 0xAA55) throws -> Data {
        guard payload.count <= Int(UInt16.max) - 4 else { throw CodecError.payloadTooLarge }
        var body = Data()
        body.appendBE(sequence)
        body.append(0) // flags: no ack request, no address, no slice info
        body.append(business)
        body.append(payload)
        var result = Data()
        result.appendBE(magic)
        result.appendBE(UInt16(body.count))
        result.append(body)
        result.appendBE(crc16XModem(body))
        return result
    }

    static func acknowledgement(business: UInt8, sequence: UInt16) throws -> Data {
        try frame(business: business, sequence: sequence, payload: Data(), magic: 0x55AA)
    }

    static func crc16XModem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021 }
        }
        return crc
    }

    /// Pairing business 0x10: `command:1 | length:BE16 | TLV(tag:1, length:BE16, value)*`.
    static func pairingFrame(sequence: UInt16, command: UInt8, fields: [(UInt8, Data)]) throws -> Data {
        var tlvs = Data()
        for (tag, value) in fields {
            tlvs.append(tag)
            tlvs.appendBE(UInt16(value.count))
            tlvs.append(value)
        }
        var payload = Data([command])
        payload.appendBE(UInt16(tlvs.count))
        payload.append(tlvs)
        return try frame(business: pairingBusiness, sequence: sequence, payload: payload)
    }

    static func pairingCommand(_ payload: Data) -> (command: UInt8, body: Data, tlvs: [UInt8: Data])? {
        let payload = Data(payload)
        guard payload.count >= 3 else { return nil }
        let length = Int(payload[1]) << 8 | Int(payload[2])
        guard length == payload.count - 3 else { return nil }
        let body = payload.subdata(in: 3..<payload.count)
        guard [17, 24, 25].contains(payload[0]) else { return (payload[0], body, [:]) }
        var tlvs: [UInt8: Data] = [:]
        var offset = 0
        while offset < body.count {
            guard offset + 3 <= body.count else { return nil }
            let size = Int(body[offset + 1]) << 8 | Int(body[offset + 2])
            guard offset + 3 + size <= body.count else { return nil }
            tlvs[body[offset]] = body.subdata(in: (offset + 3)..<(offset + 3 + size))
            offset += 3 + size
        }
        return (payload[0], body, tlvs)
    }

    /// SHA-256(random | phoneID | glassesClassicAddress | constant), used in both directions.
    static func authDigest(random: Data, deviceID: Data, classicAddress: Data) -> Data {
        var input = random
        input.append(deviceID)
        input.append(classicAddress)
        input.append(authConstant)
        return Data(SHA256.hash(data: input))
    }

    // MARK: Business messages (protobuf TransportMessage: 1 version, 2 type, 3 JSON)

    static func businessFrame(business: UInt8, sequence: UInt16, type: UInt64, json: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])))
        return try frame(business: business, sequence: sequence, payload: protobuf)
    }

    /// Global foreground notification, 0x10 raw command 31 (`1f 00 01 02`), sent by the official app's
    /// GlassesAppVisibilityNotifier and by OpenRayneo as the first frame after each connection.
    static func appVisibilityFrame(sequence: UInt16, foreground: Bool) throws -> Data {
        try frame(business: pairingBusiness, sequence: sequence, payload: Data([0x1F, 0x00, 0x01, foreground ? 0x02 : 0x01]))
    }

    // MARK: 0x13 caption session (OpenRayneo DisplayController: temporary display config = session start)

    /// OpenRayneo's default caption display configuration.
    static func captionConfig(fontSize: Int = 2) -> [String: Any] {
        ["font_size": fontSize, "content_width": 100, "max_lines": 5, "position": "center", "is_display": true, "straight_view": "original"]
    }

    /// Type 7; the glasses answer with type 8 `{sid, code, effective_config}`, code 1 = accepted.
    /// font_size 2 is OpenRayneo's default and the device-verified value.
    static func captionStartBody(sid: String, fontSize: Int = 2) -> [String: Any] {
        ["sid": sid, "force": false, "scope": "temporary", "config": captionConfig(fontSize: fontSize)]
    }

    /// Type 5, caption text mode 3. `final` marks the text as final (status 1) instead of in progress (0).
    static func captionTextBody(sid: String, text: String, final: Bool = true) -> [String: Any] {
        ["sid": sid, "mode": 3, "status": final ? 1 : 0, "content": ["source_transcript": text]]
    }

    /// OpenRayneo's clear: a full-width blank in both fields, final ("Final replaces retained text").
    static func clearBody(sid: String, prompt: Bool) -> [String: Any] {
        var content: [String: Any] = ["source_transcript": "\u{3000}", "target_translation": "\u{3000}"]
        if prompt { content["keyword_info"] = NSNull(); content["label"] = 0 }
        return ["sid": sid, "mode": prompt ? 4 : 3, "status": 1, "content": content]
    }

    /// Type 3, caption exit reason_code 10.
    static func captionStopBody(sid: String) -> [String: Any] {
        ["sid": sid, "reason_code": 10, "text": ""]
    }

    // MARK: 0x17 real-time prompt session

    static func promptStartBody(sid: String, language: String) -> [String: Any] {
        ["sid": sid, "trigger": 1, "force": false, "code": 0,
         "settings": ["mode": "conversation", "source_language": language, "target_language": language,
                      "save_audio": false, "direction": "ahead"]]
    }

    static func promptTextBody(sid: String, text: String) -> [String: Any] {
        ["sid": sid, "mode": 4, "status": 1,
         "content": ["source_transcript": text, "keyword_info": NSNull(), "label": 0]]
    }

    static func promptStopBody(sid: String) -> [String: Any] {
        ["sid": sid, "reason_code": 2, "text": ""]
    }

    // MARK: Stream decoding

    /// Pulls complete frames out of a BLE notification buffer, resynchronising on garbage.
    static func extractFrames(from buffer: inout Data) -> [Message] {
        var messages: [Message] = []
        while buffer.count >= 10 {
            let bytes = [UInt8](buffer.prefix(4))
            let isData = bytes[0] == 0xAA && bytes[1] == 0x55
            let isAck = bytes[0] == 0x55 && bytes[1] == 0xAA
            guard isData || isAck else { buffer.removeFirst(); continue }
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            guard length >= 4, !(isAck && length != 4) else { buffer.removeFirst(); continue }
            let total = 4 + length + 2
            guard buffer.count >= total else {
                if buffer.count > 65_541 { buffer.removeFirst(); continue }
                break
            }
            let frame = Data(buffer.prefix(total))
            let body = frame.subdata(in: 4..<(4 + length))
            let crc = UInt16(frame[4 + length]) << 8 | UInt16(frame[5 + length])
            guard crc16XModem(body) == crc else { buffer.removeFirst(); continue }
            buffer.removeFirst(total)
            if isAck { continue }
            let flags = body[2]
            let header = 4 + (flags & 2 == 0 ? 0 : 1) + Int(flags >> 5)
            guard body.count >= header else { continue }
            let payload = body.subdata(in: header..<body.count)
            var message = Message(businessID: body[header - 1], sequence: UInt16(body[0]) << 8 | UInt16(body[1]),
                                  needsAck: flags & 1 != 0, payload: payload)
            if message.businessID != pairingBusiness {
                let fields = protobufFields(payload)
                message.type = fields.first { $0.number == 2 }?.varint
                if let json = fields.first(where: { $0.number == 3 })?.bytes {
                    message.json = (try? JSONSerialization.jsonObject(with: json)) as? [String: AnyHashable]
                }
            }
            messages.append(message)
        }
        return messages
    }

    // MARK: Minimal protobuf helpers

    static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        while value >= 0x80 { result.append(UInt8(value & 0x7F) | 0x80); value >>= 7 }
        result.append(UInt8(value))
        return result
    }

    static func field(_ number: UInt64, varint value: UInt64) -> Data { varint(number << 3) + varint(value) }
    static func field(_ number: UInt64, bytes value: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(value.count)) + value }

    static func protobufFields(_ data: Data) -> [(number: UInt64, varint: UInt64?, bytes: Data?)] {
        let data = Data(data)
        var result: [(UInt64, UInt64?, Data?)] = []
        var offset = 0
        func readVarint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while offset < data.count, shift < 64 {
                let byte = data[offset]; offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while offset < data.count, let tag = readVarint() {
            switch tag & 7 {
            case 0: guard let value = readVarint() else { return result }; result.append((tag >> 3, value, nil))
            case 2:
                guard let length = readVarint(), length <= UInt64(data.count - offset) else { return result }
                result.append((tag >> 3, nil, data.subdata(in: offset..<(offset + Int(length)))))
                offset += Int(length)
            case 1: offset += 8
            case 5: offset += 4
            default: return result
            }
        }
        return result
    }
}

nonisolated extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}

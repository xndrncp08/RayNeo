# RayPrompt — Research findings

Date: 2026-11-19. Environment: Xcode 27.2, iOS 27.2 SDK, Swift 6.4.2, macOS 27. No iPhone or glasses were connected during this work.

## 1. RayNeo iO sources reviewed (source code, not just READMEs)

| Source | What it is | Usable here? |
| --- | --- | --- |
| **Turbo-IO** (`Research/Turbo-IO`) | Large iO research repo. The iOS "V1" standalone client is user-verified on hardware, but it links the proprietary **`RayneoNet.framework`** extracted from the official app. The pure-Swift `rayneo-protocol` / `rayneo-transport-ios` packages are explicitly marked "prototype, not lens-validated". | **No code taken.** Its own license (PolyForm Noncommercial) says it does not cover the vendor frameworks, and nothing grants redistribution of `RayneoNet`. Used only as corroborating documentation (UUIDs and the iOS device-info TLV values). |
| **sattarde/rayneo-ios-english-edition** (`Research/English`) | English translation of the Turbo-IO tree | Same conclusions as Turbo-IO |
| **OpenRayneo** (`Research/OpenRayneo`) | Apache-2.0 macOS/Android companion. **Pure Swift** BLE authentication plus Classic RFCOMM data, with live captions and prompts verified on real iO (Strix OS 1.0.5.x) from macOS. `docs/protocol.md` documents the wire contract. | **Yes**, properly licensed. Its codec, handshake and 0x17 prompt bodies were ported (see `NOTICE`). |
| **xg-glass-sdk** (`Research/xg`) | Kotlin SDK. Its RayNeo support is **X2 (Android runtime glasses)**, with X3 Pro untested. | **Not applicable to iO.** iO is a BES2800 embedded device, not Android. |
| b-d.io device page | Device summary page | Not fetched. Nothing in it changes the protocol conclusions above. |

### Verified protocol facts (from OpenRayneo's hardware-tested code, cross-checked with Turbo-IO)

- **BLE service** `0000B81D-…`, plus these characteristics:
  - send `EA8B70D5-2BD3-49AB-9C31-9C38B2C3C4F9` (write without response)
  - receive `7DB3E235-3608-41F3-A03C-955FCBD2EA4B` (notify)
  - pair-info `EA8B60C5-2BD3-49AB-9C31-9D38B1C5C5F9` (read: 6-byte classic address, bond state, 6-byte bound phone ID)
- **Frame layout:** `AA55 | len:BE16 | seq:BE16 | flags | [addr] | [slice] | businessID | payload | CRC16-XMODEM:BE16`. `55AA` frames are transport ACKs. If flag bit 0 is set on an inbound frame, you must reply with an ACK.
- **Pairing (business `0x10`):**
  1. The phone sends device info (cmd 17, TLVs 16/17/18/19/22/23/27).
  2. The glasses reply with cmd 17.
  3. The phone sends cmd 24 with `random(4)` and `SHA256(random | phoneID | glassesClassicAddr | constant)`.
  4. The glasses answer with cmd 25 carrying their own random value and proof.
  - If the glasses ask for an account-bound ECDH branch (TLV 25), it is **not implemented** anywhere public.
- **BLE carries business frames as well as auth.** OpenRayneo states BLE and SPP "both accept business frames". OpenRayneo itself sends display traffic over RFCOMM, though, which iOS apps cannot open without ExternalAccessory/MFi entitlement.
- **Real-time prompt (business `0x17`):**
  - type 1 start `{sid, trigger:1, force:false, code:0, settings:{mode:"conversation", …}}`
  - type 2 result, where `code:1` means accepted
  - type 5 text `{sid, mode:4, status:1, content:{source_transcript, keyword_info:null, label:0}}`
  - type 3 exit `reason_code:2`
  - OpenRayneo reports text delivery as `visible: "unverified"`. Even on macOS, a successful write does not prove anything appeared on the lens.
- **Not recovered by any source:** a keepalive/heartbeat (OpenRayneo explicitly does not send guessed heartbeats), fonts, positioning, or app-level fragmentation beyond the BLE MTU split.
- **Only one client can be connected.** The official RayNeo app and this app cannot hold the glasses at the same time.

### Conclusion for iOS

No public, properly licensed, **iOS-verified** pure-Swift path exists. This app ships:
1. A display abstraction with a fully working simulator. This is the default.
2. An **experimental** CoreBluetooth adapter that runs the OpenRayneo handshake and the 0x17 prompt session entirely over BLE.

Three things about the adapter are unverified until someone tests on hardware:
- whether the glasses accept 0x17 text over BLE, as opposed to SPP;
- whether a random app identity is accepted when the glasses are unbound;
- whether `0x13=1` (iOS) works for device-info tag 19.

## 2. Apple APIs (confirmed in the installed iOS 27.2 SDK `.swiftinterface` files)

- **Speech:**
  - `SpeechAnalyzer`, `SpeechTranscriber` (iOS 26+), `AnalyzerInput(buffer:bufferStartTime:)`
  - reporting options `.volatileResults`, `.fastResults`, `.alternativeTranscriptions`
  - `Result.isFinal` and `.range`
  - `AssetInventory.assetInstallationRequest(supporting:)` / `downloadAndInstall()`, and `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)`
  - The fallback is `SFSpeechRecognizer` + `SFSpeechAudioBufferRecognitionRequest` (`requiresOnDeviceRecognition`, `addsPunctuation`).
- **FoundationModels:**
  - `SystemLanguageModel.default.availability`, with `.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady`
  - `LanguageModelSession(instructions:)`, `prewarm()`, and `streamResponse(to:options:)`, which yields `Snapshot.content` as cumulative text
  - `GenerationOptions(temperature:maximumResponseTokens:)`
  - An iPhone 15 Pro Max is Apple Intelligence-eligible.
- **AVFAudio:** `AVAudioApplication.requestRecordPermission()` (iOS 17+), and AVAudioSession interruption, route-change and media-reset notifications.
- **Background execution:**
  - `UIBackgroundModes: audio` is legitimate here because the app records continuously during a user-started session.
  - `bluetooth-central` keeps glasses callbacks flowing.
  - Unverified: whether Foundation Models generation is rate-limited or refused while the app is in the background. Treat locked-screen generation as untested.

## 3. Hardware findings (2026-11-20, iPhone 15 Pro Max + RayNeo iO-E081)

**Confirmed by the user's logs:**
- discovery, LE connection, B81D and all three characteristics;
- a pair-info read (bond state 2);
- the full cmd 17/24/25 authentication. The glasses' proof verified, using the glasses-bound identity.

**`0x17` type 1 (prompt start) got no reply at all:** no type 2 acknowledgement, no type 3 close, no type 4 audio. The app then wrongly reported Ready after an 8 s timeout. That is fixed: the session is now reported as UNCONFIRMED.

**`RX 0x0E type 5 {action=2, mode=1, state=3}`** belongs to OpenRayneo's native-recording business (`NativeRecordingController`: type 5 is the reconnect/status report). Its import path checks `state == 3`, the state in which no recording is active, before importing offline recordings. This is a device status push, **unrelated to display or session state**.

**Likely reasons the prompt start went unanswered.** None of these is proven.
1. OpenRayneo sends display sessions only once its RFCOMM data link is up. A prompt session also streams the glasses' microphone audio (type 4), which is designed for that link.
2. We did not send the foreground app-visibility frame (`0x10` cmd 31, `1f 00 01 02`). The official app and OpenRayneo send it after every connection. **It is now sent after authentication.**
3. The glasses' display may have been off. b-d.io says sessions fail to start then.
4. The official app may have been holding a session or channel.

**Caption session (`0x13`)**, from OpenRayneo `DisplayController` (`applyCaptionDisplay`, text and stop routes). Now implemented as the default mode.

| Step | Message |
|---|---|
| Start | type 7 `{sid, force:false, scope:"temporary", config:{font_size:2, content_width:100, max_lines:5, position:"center", is_display:true, straight_view:"original"}}` |
| Acknowledgement | type 8 `{sid, code, effective_config}`, code 1 = accepted |
| Text | type 5 `{sid, mode:3, status:0/1, content:{source_transcript[, target_translation]}}` |
| Close | type 3 `{sid, reason_code:10, text:""}` |

b-d.io's iPhone, CoreBluetooth-only success is a caption session; it publishes no field names, so they come from OpenRayneo.

**"Conversation ended": origin not confirmed.**
- The only "conversation" our app sends is the `0x17` start (`mode:"conversation"`).
- Other candidates: our earlier type 3 close (sent by the old Reconnect = disconnect + connect), a link teardown, or the official app reacting to our non-mixable audio session.
- Caption mode sends no `0x17` frames. If the message still appears in caption mode with the microphone off, the official app is the likely source.

**Unknown / not implemented:** firmware version (no verified read mechanism), a keepalive (none recovered), and the classic-Bluetooth data channel (needs ExternalAccessory with `com.rayneo.venus.pub`; untested for sideloaded apps).

**Verified on hardware (2026-11-20, iO-E081):**
- The `0x13` type 7 caption start makes the glasses show the RayNeo Live Captions introduction.
- A following `0x13` type 5 `{mode:3, status:1, content:{source_transcript:"HELLO FROM IPHONE"}}` **replaced the introduction with the exact text** (user observation).
- The type 8 acknowledgement never arrived.

So on this firmware, the absence of an acknowledgement does not mean rejection. The app's *caption compatibility mode* (opt-in, caption only) sends on such sessions.

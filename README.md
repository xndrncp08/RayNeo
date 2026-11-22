# RayPrompt

A hands-free AI assistant and adaptive teleprompter for smart glasses.

RayPrompt is a native SwiftUI iPhone app for conversations, coding, presentations, and hands-free guidance. It transcribes speech, detects questions and contextual follow-ups, generates answers, and keeps the glasses display aligned with what you are saying. Live assistance requires informed consent from everyone involved.

## Core features

- Continuous speech recognition, interruption recovery, transcript consolidation, and project-name normalization.
- Automatic question detection and contextual answer handoff without a manual Continue step, with confidence gates, answer locking, queueing, and undo.
- Apple Foundation Models on-device generation, optional Gemini Flash cloud generation, and configurable local fallback.
- Adaptive teleprompter with speech synchronization, sentence frames, look-ahead, and manual controls.
- Hands-free Code Tutor with coordinated explanation/code walkthroughs, temporary previews, pagination, and code display calibration.
- Optional VS Code companion for editor-based step completion over local Wi-Fi.
- Editable personal memory, project knowledge, repository import with secret filtering, and bounded context retrieval.
- RayNeo iO Bluetooth LE communication, reconnection recovery, an in-app display simulator, and diagnostics.

## Hardware and requirements

- **Glasses:** RayNeo iO. Other models and brands are not verified. The in-app display simulator works without glasses.
- **iPhone:** iOS 26 or later. Local Foundation Models generation requires an Apple Intelligence capable iPhone with Apple Intelligence enabled and its model available. Gemini requires connectivity, explicit opt-in, and a user-provided key.
- **Mac:** Xcode 26 or later with Swift 6; this project is currently checked with **Xcode 27.2**. Earlier Xcode versions have not been verified against this project format.
- **Signing:** preserve the configured team and bundle ID when updating the existing installation. Separate developers need their own signing setup.
- **VS Code:** 1.85 or later; Node.js for extension development. No third-party runtime dependencies are used by the extension.

## Architecture

The public product is RayPrompt. Original `RayNeoInterviewCompanion` source directories, modules, Xcode targets, bundle identifiers, and Keychain identities remain stable for installation compatibility.

| Component | Responsibility |
| --- | --- |
| `App/` | Session lifecycle, permissions, settings, diagnostics, and service coordination |
| `Audio/`, `Speech/`, `Speaker/` | Microphone capture, recognition, transcript turns, and heuristic speaker evidence |
| `Intelligence/` | Question routing, model providers, answer validation, memory, repository import, and vocabulary |
| `Conversation/` | Answer locking, contextual handoff, reading alignment, walkthrough progression, and code layout |
| `Glasses/` | BLE protocol, connection/session recovery, serialized captions, and simulated display |
| `Views/` | Dashboard, settings, memory editing, calibration, and diagnostics |
| `Tools/vscode-code-tutor/` | Optional VS Code extension |
| `RayNeoInterviewCompanionTests/` | Swift Testing suites with injected hardware, model, network, and clock doubles |

App component paths are relative to `RayNeoInterviewCompanion/RayNeoInterviewCompanion/`; `Tools/` and the tests are its siblings. The app has no external Swift package dependencies. Separate upstream research checkouts and firmware in the local workspace are not build dependencies and are excluded from publication.

### Speech recognition pipeline

`AVAudioEngine` feeds `SpeechAnalyzer`/`SpeechTranscriber`, with an `SFSpeechRecognizer` fallback and recognizer recovery. Turn assembly consolidates partial/final transcript revisions; vocabulary normalization resolves configured project names. Turn detection and classification separate questions, follow-ups, reading, and unrelated speech. Speaker evidence uses a single microphone and pitch/level heuristics, so it cannot reliably identify everyone.

### Gemini and Apple Foundation Models

Apple's Foundation Models provider runs locally when available. **Auto** stays on-device. Gemini requires an explicit opt-in, a saved key, and selection of the cloud provider. The question and relevant prompt context go to Google; a separate context-sharing setting controls personal memory and recent conversation. The API key is stored in the iOS Keychain using `WhenUnlockedThisDeviceOnly`, and sent in a request header rather than the URL.

Configured fallback can use Apple after supported Gemini failures before any text is produced. Partial answers are never spliced across providers. Use **Test Gemini Connection** to check your account and selected model; model availability and quotas can change. Gemma is an unavailable placeholder, not an installed local model. See [Gemini configuration](RayNeoInterviewCompanion/Documentation/GEMINI.md).

### BLE communication and adaptive teleprompter

The RayNeo adapter handles discovery, authentication, caption (`0x13`) and experimental prompt (`0x17`) sessions, timeouts, and bounded reconnects. The presenter serializes writes and restores the current answer or persistent walkthrough after reconnecting. Expired temporary code previews are not restored.

Reading alignment advances sentence frames or look-ahead windows from spoken-word evidence. Code has a separate paginator and calibration settings. A successful Bluetooth submission **does not prove lens visibility**. Font, row count, wrapping, indentation, and frame replacement need physical calibration.

### Automatic contextual question handoff

Confident follow-ups can replace the current answer automatically. Less certain turns wait or prepare an answer without replacing the one being read. Cancelled or failed generation preserves the previous answer. Locking, manual navigation, and undo remain available. Silence alone does not establish completion of an explanation.

### Code Tutor and VS Code companion

Guided answers alternate explanation and code blocks. Explanation completion uses alignment and coverage evidence; code remains until an explicit command, manual control, configured timer, or paired editor supplies completion evidence. Generated code is checked structurally but **never executed** by the app.

The [VS Code companion](RayNeoInterviewCompanion/Tools/vscode-code-tutor/README.md) receives expected generated lines and returns a file name, per-line presence flags, and error count. It does not send your editor's source. Pairing uses an HMAC challenge, but local-network messages are not encrypted. Use a trusted Wi-Fi network and turn pairing off when finished. See [Code Tutor](RayNeoInterviewCompanion/Documentation/CODE_TUTOR.md).

### Personal memory system

Profile facts, project summaries, and imported documents are stored locally with file protection. Retrieval selects bounded relevant context. Session conversation memory is separate and temporary. Import skips sensitive files and redacts common secret formats; review imported information and exports before sharing. Settings provides editing, personal-memory deletion, project-index deletion, and export.

## Installation and configuration

1. Clone the repository and open `RayNeoInterviewCompanion/RayNeoInterviewCompanion.xcodeproj` in Xcode.
2. Choose the shared **RayNeoInterviewCompanion** scheme. Keep the existing signing team and bundle ID for updates to the installed app; configure your own team only for a separate developer setup.
3. Select your iPhone, enable Developer Mode if needed, and run. The app appears as **RayPrompt**.
4. Start a session, review consent, and grant microphone and speech permissions. Stop when assistance is no longer authorized.
5. For local generation, enable Apple Intelligence and allow required speech/model downloads to complete.
6. For Gemini, open **RayPrompt Settings → Gemini Flash**, enable the opt-in, save your own key, test the connection, then select Gemini. No `.env` file or embedded credential is required.
7. Select RayNeo iO, connect, and follow the [physical-device checklist](RayNeoInterviewCompanion/Documentation/HARDWARE_TESTING.md). Calibrate code separately.
8. Optionally run the VS Code companion in an Extension Development Host, with `--extensionDevelopmentPath` pointing to `RayNeoInterviewCompanion/Tools/vscode-code-tutor`, then run **Code Tutor: Pair with iPhone** on the same trusted Wi-Fi.

See [Installation](RayNeoInterviewCompanion/Documentation/INSTALLATION.md) for device setup. Never commit API keys, signing material, personal memory exports, or conversation recordings.

## Development and tests

Run from the repository root. Substitute an available simulator from `xcrun simctl list devices available` if necessary.

```sh
xcodebuild test \
  -project RayNeoInterviewCompanion/RayNeoInterviewCompanion.xcodeproj \
  -scheme RayNeoInterviewCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project RayNeoInterviewCompanion/RayNeoInterviewCompanion.xcodeproj \
  -scheme RayNeoInterviewCompanion -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO

xcodebuild build \
  -project RayNeoInterviewCompanion/RayNeoInterviewCompanion.xcodeproj \
  -scheme RayNeoInterviewCompanion -configuration Release \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO

xcodebuild analyze \
  -project RayNeoInterviewCompanion/RayNeoInterviewCompanion.xcodeproj \
  -scheme RayNeoInterviewCompanion -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO

node --check RayNeoInterviewCompanion/Tools/vscode-code-tutor/extension.js
```

Unsigned iPhone builds validate compilation, not provisioning or installation. Tests use mocks and synthetic inputs; simulator success does not verify real microphone, cloud, model, or glasses behavior. See [current verification](RayNeoInterviewCompanion/Documentation/VERIFICATION.md) for results and their scope.

## Privacy, consent, and current limitations

- Audio is processed on the phone and is not saved. Session transcripts and conversation context are temporary. Explicitly entered personal memory persists locally.
- Gemini sends text to Google when enabled. Review current provider terms before sending sensitive material. Speech/model downloads and cloud access require connectivity.
- Diagnostics and manual exports can include questions, answers, code, and device information. Review and keep them private. Local secrets, runtime exports, recordings, signing material, and Xcode user state are excluded by `.gitignore`.
- Use live assistance only with informed consent and where permitted. Generated facts and code can be wrong and require review.
- Recognition quality, speaker separation, background execution, latency, battery life, and BLE behavior vary with devices and conditions.
- Source publication does not deploy the app, distribute it through the App Store, or create a public release.

## Hardware verification status

Earlier user observations documented BLE authentication and a visible test caption on RayNeo iO. Later handoff entries describe display and conversation issues addressed in software. Those are historical observations, not a new hardware acceptance test.

**Recent code-display density, wrapping, indentation, calibration, and explanation-to-code transitions have not been verified on RayNeo hardware in this publication pass.** The physical-device checklist remains necessary. Sending bytes, passing tests, and building for iPhone do not establish lens visibility or hands-free behavior in real conditions.

## Documentation and attribution

- [Architecture](RayNeoInterviewCompanion/Documentation/ARCHITECTURE.md)
- [Troubleshooting](RayNeoInterviewCompanion/Documentation/TROUBLESHOOTING.md)
- [Historical handoff](RayNeoInterviewCompanion/Documentation/HANDOFF.md) — dated evidence; earlier test counts are not current results
- [Protocol research](RayNeoInterviewCompanion/Documentation/RESEARCH.md)
- [Third-party notices](RayNeoInterviewCompanion/NOTICE)

BLE logic derived from [OpenRayneo](https://github.com/Tobi1chi/OpenRayneo) retains its Apache-2.0 attribution in `NOTICE`. No vendor SDK or Turbo-IO code/binaries are included in the app. RayNeo is a trademark of its owner; this project is not affiliated with or endorsed by RayNeo.

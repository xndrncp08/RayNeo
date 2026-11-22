# RayPrompt — Publication verification

Verified on 2026-11-21 with Xcode 27.2 (27B52), using the existing shared scheme. This records the current publication pass; historical handoff counts describe earlier snapshots.

| Check | Result | Scope |
| --- | --- | --- |
| Complete automated suite | **359 tests in 65 suites passed**, zero failures or skips | One complete run on iPhone 17 / iOS 27.2 simulator; parameterized cases produced 482 invocations |
| Debug iPhone build | **Passed** | Generic iOS arm64, existing automatic signing; built signature verified with `codesign --verify --deep --strict` |
| Release iPhone build | **Passed** | Generic iOS arm64, existing automatic signing; built signature verified with `codesign --verify --deep --strict` |
| Xcode static analysis | **Passed**, no warnings or errors | Debug, generic iOS |
| Project loading | **Passed** | `xcodebuild -list` loaded both targets, configurations, and the shared scheme |
| Xcode GUI opening | **Not verified** | Desktop access was unavailable; command-line project loading is separate evidence |
| Product display name | **Passed** | Both built iPhone Info.plists and the simulator app contain `CFBundleDisplayName = RayPrompt`; dashboard and Settings use RayPrompt |
| Bluetooth and installation identity | **Preserved** | Compared with pre-edit baseline: BLE source, UUIDs, protocol constants, bundle IDs, signing settings, Keychain identity, and shared scheme unchanged |
| Runtime behavior and tests | **Preserved** | Audio, speech, AI, memory, conversation, model, and application coordination source and every existing test unchanged |
| VS Code extension | **Syntax check passed** | `node --check`; runtime editor pairing not exercised in this pass |

Build and test logs contain Xcode's `Metadata extraction skipped, no AppIntents.framework dependency found` warning. No Swift compiler warnings or errors were emitted. Static analysis emitted no warnings.

## Security review

- Inventoried the workspace, including hidden/configuration files, and scanned current files with Gitleaks before staging.
- Reviewed the intended source snapshot separately. Its three scanner findings are deliberately synthetic inputs in `MemoryAndConversationTests.swift`, testing API-key/JWT/password redaction and repository import. They are not live credentials and were retained so security tests remain intact.
- No real Gemini API key, account token, signing private key, personal recording, conversation export, or diagnostic log was found in the staged app source.
- Gemini already uses a user-entered iOS Keychain credential; no hardcoded-key migration or configuration file is needed.
- Existing noncredential profile/project seed defaults remain in source to preserve personal-memory behavior. No saved runtime memory or transcript export is included. Review those defaults before sharing beyond the intended private repository.
- Separate upstream research checkouts, firmware, and binaries remain local and are excluded. Scanner findings there are outside the upload; they include test/configuration literals and upstream application identity constants.
- `.gitignore` excludes local secret configuration, signing material, recordings, runtime memory exports, logs, build outputs, Xcode user state, dependencies, and editor caches. Shared project configuration, source, tests, schemes, and extension manifests are included.
- No known live user credential exposure was identified by this audit. Rotate any credential separately known to have been shared or previously committed; pattern scanning cannot prove the absence of all possible secrets.

## Hardware work remaining

No app installation or physical iPhone/RayNeo acceptance test was performed in this pass. A signed build is not physical-device verification. In particular, recent code-display density, wrapping, indentation, frame replacement, calibration, and explanation-to-code timing remain unverified on the glasses. Follow `HARDWARE_TESTING.md`; measure live speech, model latency, handoff, reconnects, battery, and noisy-room behavior on the actual equipment.

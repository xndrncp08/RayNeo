# RayPrompt — Troubleshooting

| Symptom | Fix |
| --- | --- |
| AI model: "turn on Apple Intelligence" / "model is still downloading" | Go to Settings › Apple Intelligence & Siri and turn it on. Keep the phone on Wi-Fi and charging until the model finishes downloading. |
| AI model: "device does not support Apple Intelligence" | Only Apple Intelligence-capable iPhones can generate answers. Everything else (transcription, lock, display) still works. |
| Speech: Unavailable / unsupported locale | Pick another English variant in Settings. The first run needs a network connection to download the speech model. |
| Speech keeps "Recovering" | Stop and restart the session. After 5 consecutive failures the app stops retrying and shows an error. |
| Questions not detected | Lower the **Question threshold**, raise **End-of-turn silence** if the speaker pauses mid-question, and turn on the semantic check. |
| Answers triggered by my own voice | Calibrate your voice, lower **Ignore speech matching the answer**, turn off **Auto-advance**, or raise **Minimum time an answer stays**. |
| New questions never replace the answer | Expected while the answer is fresh: tap **Next** or **Answer it now**. Otherwise lower **Auto-advance minimum score**. |
| Input switched to a headset | The app forces the built-in mic. If you picked another input in Settings, set it back to *iPhone microphone*. |
| Glasses: "rejected authentication" | Unbind the glasses in the official app, forget them in iOS Bluetooth settings, re-enter pairing mode, then tap Reconnect. |
| Glasses: "account-bound ECDH" | This firmware/binding mode is not supported by any public implementation. Use the in-app display. |
| Glasses connect but nothing shows | Possible: BLE may not carry display text on your firmware. See HARDWARE_TESTING.md B. |
| App will not open after a week | Free-account signing expired. Re-run from Xcode. |
| "Untrusted developer" | Go to Settings › General › VPN & Device Management, open your profile and tap Trust. |

## Crash right after granting permissions (`_dispatch_assert_queue_fail`)

This was fixed on 2026-11-19. `SFSpeechRecognizer.requestAuthorization` calls its handler on a background queue. The handler closure was written inside `@MainActor AppModel`, so Swift 6 added a main-queue assertion that trapped. It now lives in the `nonisolated` `AppModel.speechAuthorization`. Regression tests are in `PermissionCallbackTests`.

To exercise the real framework path in the simulator without a prompt, pre-grant both permissions:

```sh
SIM=<simulator-udid>; BID=com.derrancap.RayNeoInterviewCompanion
xcrun simctl privacy $SIM grant microphone $BID
DB=~/Library/Developer/CoreSimulator/Devices/$SIM/data/Library/TCC/TCC.db
sqlite3 "$DB" "insert or replace into access select 'kTCCServiceSpeechRecognition', client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified, pid, pid_version, boot_uuid, last_reminded from access where client='$BID' and service='kTCCServiceMicrophone';"
```

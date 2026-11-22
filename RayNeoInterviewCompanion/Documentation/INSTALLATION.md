# RayPrompt — Installation

## Requirements

- Mac with Xcode 26 or later (this project was built with Xcode 27.2).
- iPhone with Apple Intelligence (iPhone 15 Pro / Pro Max or newer) on iOS 26 or later, with **Apple Intelligence turned on** in Settings.
- A free Apple ID is enough. No paid developer membership is needed.

## Steps

1. Open `RayNeoInterviewCompanion/RayNeoInterviewCompanion.xcodeproj`.
2. In Xcode, go to **Settings › Accounts**, click **+**, choose **Apple ID** and sign in.
3. Select the **RayNeoInterviewCompanion** target, then **Signing & Capabilities**:
   - Tick **Automatically manage signing**.
   - Set **Team** to *Your Name (Personal Team)*.
   - For a separate developer installation only, choose a unique bundle ID if required. When updating the existing installation, preserve its bundle ID and signing team to retain app data and Keychain compatibility.
4. Connect the iPhone by USB and unlock it. Tap **Trust** on the phone.
5. On the iPhone, turn on **Settings › Privacy & Security › Developer Mode**. The phone restarts.
6. In Xcode, pick your iPhone as the run destination and press **⌘R**.
7. If the first launch is blocked, go to **Settings › General › VPN & Device Management**, open your developer profile and tap **Trust**.
8. In the app, tap **Start Session**, confirm the consent screen, and allow microphone and speech recognition access. On first use the speech model may download (needs a network connection once).

After installation the app runs without the Mac.

## Free Apple ID limitations

- The app **expires after 7 days**. Reconnect the phone and press ⌘R to re-sign it. Your settings and knowledge base are kept.
- You can have at most 3 sideloaded apps per device, and only a limited number of new bundle IDs per week.
- No TestFlight or App Store distribution (not needed here).

## Command-line build (simulator, no signing)

```sh
xcodebuild test -project RayNeoInterviewCompanion.xcodeproj -scheme RayNeoInterviewCompanion \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

The simulator has no Apple Intelligence model and no real microphone. Use it for UI checks and the automated tests only.

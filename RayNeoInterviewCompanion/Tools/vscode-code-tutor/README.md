# RayPrompt Code Tutor companion (VS Code)

**VS Code ↔ encrypted local link ↔ RayPrompt (iPhone) → Bluetooth LE → RayNeo iO**

## Setup (once)

1. **iPhone:**
   - Settings › Conversation › **Allow paired VS Code**, then **Pair new editor**.
   - Note the address (e.g. `192.168.1.20:48654`) and the code `XXXXX-XXXXX` (valid 2 minutes, one attempt).
2. **Install the extension on the Mac:**
   - Package this folder with `npx @vscode/vsce package`, then `code --install-extension rayprompt-code-tutor-companion-0.2.0.vsix`.
   - Or open this folder in VS Code and press F5 (Extension Development Host).
3. **Pair:** run **RayPrompt: Pair with iPhone** and enter the address and the code.

After that the extension reconnects by itself (status bar: `RayPrompt: connected`):
- on VS Code start, and after Wi-Fi changes or iPhone sleep;
- with exponential backoff (1 s … 30 s), finding the iPhone again through Bonjour (`dns-sd`, macOS).

## What it sends

| Always (metadata) | Only when you run the command and confirm |
|---|---|
| file name, language, cursor line/column, current function (language service), selection size | **Explain Selection**: the selected code |
| per-line yes/no for the current Code Tutor step + whether its names are real symbols | **Explain Error at Cursor**: the error and the 7 lines around it |
| diagnostic summaries (message, severity, line), only changed ones | |
| test/build task results (exit code from the task runner) | |

**Never sent:**
- `.env*`, keys, certificates, files named like credentials, secrets or tokens. Such files show as "(private file)" and get no checks.
- Secret-looking values in excerpts are redacted; excerpts are at most 4 KB.
- Whole files or repositories.

## Security

| Aspect | How |
|---|---|
| First pairing | X25519 key agreement with the one-time code (≈50 bits) mixed into HKDF; both sides prove the code |
| Trust | A trust key, kept in VS Code SecretStorage and the iPhone Keychain, valid 30 days |
| Each reconnection | Fresh ephemeral keys, authenticated by the trust key |
| Every message | ChaCha20-Poly1305; strict sequence numbers and timestamps reject replayed, reordered, stale or tampered messages |
| iPhone limits | Message size, rate limiting, a 30 s heartbeat watchdog, at most 4 half-open connections |

- **Pairing attempts:** one wrong code burns it.
- **Same Wi-Fi is not the security boundary:** a device on the network without the trust key cannot connect or read anything.
- **Revoke:** **RayPrompt: Forget iPhone** here, and **Forget** on the iPhone.

## Commands

**Pair** · **Reconnect** · **Disconnect** · **Forget iPhone** · **Explain Selection** · **Explain Error at Cursor** · **Dismiss Help on Glasses** · **Toggle Automatic Step Progression** · **Show Connection Log** (metrics: connects, reconnects, failures, RTT).

## Limits

- **iOS:** RayPrompt listens only while it is active. When iOS suspends it, the extension keeps retrying and reconnects once it is open again.
- **Structure checks are not proof:** present lines, existing symbols and zero errors do not mean the code is correct.
- **Not yet verified on real devices**, including the Bonjour lookup.

**Tests:** `npm test`, which runs `node --test test/*.test.js`. The protocol vectors are shared with the Swift tests.

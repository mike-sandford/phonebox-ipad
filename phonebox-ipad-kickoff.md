# PhoneBox for iPad: kickoff

Personal project, separate from PFG / Relologix. Paste the "Kickoff prompt" section into a new Claude Code
session started in the project folder on the MacBook.

## Goal

A native iPadOS app that does for an iPad what PhoneBox's Android app does for a phone: shows the PhoneBox panel
full screen and talks to the PhoneBox agent on the Mac over Wi-Fi. Personal use, installed from Xcode (no App Store).

## Decisions already made

- Device: iPad 7th generation, iPadOS 18 (current Safari/WebKit, so the panel should run unchanged).
- Host: the PhoneBox agent on the Mac (Mac mini preferred as the always-on host; MacBook for development).
- Transport: Wi-Fi only (agent HTTPS port 8766). No USB, no Tailscale, no jailbreak, no screen streaming.
- Approach: a native wrapper mirroring the Android app, NOT a browser client. The agent's security model
  (pinned certificate + paired key) stays as it is; ideally the agent needs no changes.
- Signing: Michael's paid Apple developer account; install with Xcode or ad hoc.
- Kiosk: supervise the iPad with Apple Configurator, then Single App Mode (supervising ERASES the iPad).
  Home Assistant either through PhoneBox's own HA widgets or the HA app beside it (then no single-app lock).

## What the panel expects from its host (measured in `android/app/src/main/assets/www/main.js`)

- Requests to `/agent/api/...` are intercepted by the host and forwarded to the agent (`export const API = '/agent/api'`).
- `window.onAgentStream(event, data)`: events `open`, `close`, `state`, `work`, `spectrum`, `event` (JSON strings).
  The host owns the stream (Android: `AgentStream.kt`); polling is the fallback when the stream is off.
- `window.onAppPause(paused)`: the host reports when nobody can see the panel.
- `window.Android` bridge with a per-frame key (`window.__phoneboxKey`). Methods: battery, buzz, haptic, is24Hour,
  pcs, selectPc, forgetPc, setBrightness, setHomeScreen, setOrientation, setPinned, setVolumeKeys, setLanguage,
  transport, sensors, version, canListen, listen, stopListening, cancelListening, trackpad, canWake, wakePc.
  The panel already runs with `bridge === null` (no host), so each method is optional.
- Also referenced: `window.onAndroidKey`, `window.onAndroidSensor`, `window.onAndroidBack`.

## Build plan

1. Read the Android shell first (MainActivity, AgentLink, AgentStream, pairing, bridge) and write down the exact
   protocol: how the key is sent, the pairing exchange (QR payload: PC addresses, certificate fingerprint,
   one-time code), the stream endpoint, how the certificate is pinned.
2. Xcode project (Swift, UIKit or SwiftUI shell, iPadOS 18 target), panel files copied in from
   `android/app/src/main/assets/www` at build time (a build-phase script, so they are never hand-edited copies).
3. `WKURLSchemeHandler` serving the bundled panel and forwarding `/agent/*` over `URLSession` with certificate
   pinning in `urlSession(_:didReceive:)`; no CORS, no mixed content, same as Android.
4. Pairing: scan the agent's QR code (camera / VisionKit), confirm the check code, store the key in the Keychain.
5. Event stream: native SSE reader calling `window.onAgentStream`; reconnect with backoff; pause/resume calls
   `window.onAppPause`.
6. Bridge: `WKScriptMessageHandler` exposing the methods that make sense on iPad (brightness, is24Hour, version,
   battery, setPinned/orientation, pcs/selectPc/forgetPc, haptic where available), keyed like Android.
7. Screen on (`isIdleTimerDisabled`), full screen, no status bar, home indicator auto-hidden.
8. iPad layouts: landscape 1080x810 and portrait 810x1080 templates; add an "iPad" size to the editor preview.
9. On-device check of every widget; then supervision + Single App Mode.

## Michael's checklist before the first session on the MacBook

- [ ] Fork `ersinkoc/phonebox` to your PERSONAL GitHub account (not a PFG organisation).
- [ ] Create the folder, e.g. `~/Projects/phonebox-ipad`, and clone the fork into it.
- [ ] Xcode installed (current version), signed in with the developer account (Xcode > Settings > Accounts).
- [ ] iPad: update iPadOS, connect by cable, tap Trust, turn on Settings > Privacy & Security > Developer Mode.
- [ ] Install the PhoneBox agent on the Mac (`setup.sh`, or .NET 10 SDK to run from source) and turn on
      General > Wi-Fi & Tailscale > "Let the phone connect without the USB cable".
- [ ] Python 3 available (for `python3 tools/demo-server.py`, the quick Safari check).
- [ ] Pick a bundle identifier (e.g. `com.<your-name>.phonebox`).
- [ ] Start Claude Code locally in that folder on the Mac (builds, signing and the iPad all live there).

## Kickoff prompt

> We're building a native iPadOS app for PhoneBox (this repo is my personal fork of ersinkoc/phonebox).
> Read phonebox-ipad-kickoff.md (in the repo root) for the decisions and plan. Start with step 1: read the Android shell and
> write down the host protocol, then set up the Xcode project. Target: iPad 7th gen on iPadOS 18, Wi-Fi to the
> agent on this Mac, certificate pinning as Android does it. Don't change the agent unless the protocol requires it.

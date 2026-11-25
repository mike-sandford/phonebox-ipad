# PhoneBox for iPad

A native iPadOS shell for the PhoneBox panel, the iPad counterpart of the Android app in `android/`. It shows the
panel full screen and talks to the PhoneBox agent on the Mac over Wi-Fi, pinning the agent's certificate and sending the
paired key exactly as the Android app does. The agent needs no changes. How the pieces fit: [PROTOCOL.md](PROTOCOL.md).

Target: iPad (7th generation) on iPadOS 18. Deployment target iPadOS 17, iPad only. Personal install from Xcode.

## Build and run (on the Mac)

1. `brew install xcodegen` (once).
2. `ios/setup.sh`. The first run creates `ios/Signing.xcconfig` and stops: put your Team ID
   (Xcode › Settings › Accounts › your team) and a bundle identifier such as `com.yourname.phonebox` in it.
3. `ios/setup.sh` again: generates `ios/PhoneBox.xcodeproj`.
4. Open `ios/PhoneBox.xcodeproj`, connect the iPad by cable (Trust, and Settings › Privacy & Security › Developer Mode
   on), pick it as the run destination and press Run. The first launch asks for **Local Network** access: allow it.
5. On the Mac, in the PhoneBox settings: General › Wi-Fi & Tailscale › "Let the phone connect without the USB cable",
   then Wi-Fi › "Pair a phone over Wi-Fi". On the iPad tap "Scan the pairing QR code" (or scan it with the Camera app
   and choose "Open in PhoneBox"), compare the check code, and tap Pair.

Run `ios/setup.sh` again after pulling changes that add or remove Swift files. The panel itself (`www`) is copied
from `android/app/src/main/assets/www` on every build, so panel changes need no extra step.

Debugging the panel: Safari on the Mac › Develop › (the iPad) › PhoneBox (Debug builds only).

## Using it

* Hold **three fingers** on the screen for a second for the app menu: scan a pairing QR code, switch or forget a
  paired computer, reload the panel.
* The screen stays on while the panel is in front. For a kiosk, supervise the iPad with Apple Configurator and turn on
  Single App Mode (supervising erases the iPad), or use Guided Access (Settings › Accessibility) without supervising.

## What is done and what is not

Done (scaffold, not yet built on a device):

* Panel served from the app bundle under `pbpanel://app/`, `/agent/*` forwarded to the agent with certificate pinning,
  the key, and Android's rules (only the panel may use it; a POST is never sent twice).
* Pairing by QR code (in-app scanner or `phonebox://pair` link), stored in the Keychain; several computers.
* Live stream (`/api/stream`) to `window.onAgentStream`, `onAppPause` when the app is hidden.
* Bridge: battery, is24Hour, pcs / selectPc / forgetPc, setBrightness, setOrientation, transport, version, sensors
  (none), trackpad (HTTP), setLanguage.
* Full screen, no status bar, home indicator hidden, screen kept on.

Next:

* Build and fix on the device; check every widget (plan step 9).
* iPad layout templates (landscape 1080×810, portrait 810×1080) and an "iPad" size in the editor preview (step 8,
  agent settings page, which is an agent change: ask first).
* Standby (release the screen when the computer is gone), Dictation (`SFSpeechRecognizer`), trackpad over WebSocket.
* App icon.
* Not possible on iPad without special entitlements: Wake-on-LAN (UDP broadcast), volume keys, vibration, room-light
  and proximity sensors, home-screen replacement. The panel hides those features when the bridge lacks them.

## Android-only bits in the agent to revisit

Things the agent shows or does that assume an Android phone (to address later, all agent changes):

* Settings › Wi-Fi › Pair a phone over Wi-Fi shows an "install the Android app" QR code (an APK link) beside the
  pairing QR code.
* The agent offers APK updates for the phone app; the iPad avoids them by sending `X-PhoneBox-App: ipad-<version>`.
* Settings › General "install the phone app" and the USB / adb steps in `setup.sh` (use `--no-phone`).
* "More rows on a tablet" (12 × 10 on the iPad) is not in release 0.9.29 yet; it needs the agent from source or the
  next release.

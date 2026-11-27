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

Run `ios/setup.sh` again after pulling changes that add or remove files under `ios/PhoneBox`. The panel itself (`www`) is copied
from `android/app/src/main/assets/www` on every build, so panel changes need no extra step.

Debugging the panel: Safari on the Mac › Develop › (the iPad) › PhoneBox (Debug builds only).

## Using it

* Hold **three fingers** on the screen for a second for the app menu: scan a pairing QR code, switch or forget a
  paired computer, reload the panel.
* **Standby** follows the computer's Settings › Display › Standby. "When the agent stops answering" (or "when the
  USB charge is cut", which on the iPad means "not charging") turns the screen black with the backlight at its lowest
  after the grace period, and lights the panel again by itself when the computer is back. A tap shows the panel for 30
  seconds. The iPad stays awake meanwhile: an app cannot switch a locked iPad's screen back on.
* **Dictation** uses Apple's speech recognition. The first tap asks for Speech Recognition and the microphone; if you
  refused, turn them on in Settings › Apps › PhoneBox. "On this device only" works where the iPad's language supports
  it (otherwise the widget says so).
* The screen stays on while the panel is in front. For a kiosk, supervise the iPad with Apple Configurator and turn on
  Single App Mode (supervising erases the iPad), or use Guided Access (Settings › Accessibility) without supervising.

## What is done and what is not

Done (built and running on an iPad 7th generation):

* Panel served from the app bundle under `pbpanel://app/`, `/agent/*` forwarded to the agent with certificate pinning,
  the key, and Android's rules (only the panel may use it; a POST is never sent twice).
* Pairing by QR code (in-app scanner or `phonebox://pair` link), stored in the Keychain; several computers.
* Live stream (`/api/stream`) to `window.onAgentStream`, `onAppPause` when the app is hidden.
* Bridge: battery, is24Hour, pcs / selectPc / forgetPc, setBrightness, setOrientation, transport, version, sensors
  (none), trackpad (HTTP), setLanguage.
* Full screen, no status bar, home indicator hidden, screen kept on.
* Standby, Dictation, app icon (the Android icon).
* iPad page templates (12 × 10) in the agent's New page dialog.

Next:

* Trackpad over WebSocket (it works over HTTP now).
* Not possible on iPad without special entitlements: Wake-on-LAN (UDP broadcast), volume keys, vibration, room-light
  and proximity sensors, home-screen replacement. The panel hides those features when the bridge lacks them.

## Android-only bits in the agent to revisit

Things the agent shows or does that assume an Android phone (to address later, all agent changes):

* Settings › Wi-Fi › Pair a phone over Wi-Fi shows an "install the app" QR code (an APK link) beside the pairing QR
  code. It is now labelled "Android"; an iPad skips it and scans the second one.
* The agent offers APK updates for the phone app; the iPad avoids them by sending `X-PhoneBox-App: ipad-<version>`.
* Settings › General "install the phone app" and the USB / adb steps in `setup.sh` (use `--no-phone`).
* The settings on the Mac still speak of "the phone" in most places (they are shared with the Android app). The Standby
  hint and the pairing dialog mention the iPad. On the iPad itself, in English, the panel says "Mac" for "PC" and
  "computer" when the agent runs on a Mac, and its Android-only hints (dictation, offline help) are worded for the iPad.
* "More rows on a tablet" (12 × 10 on the iPad) is not in release 0.9.29 yet; it needs the agent from source or the
  next release.

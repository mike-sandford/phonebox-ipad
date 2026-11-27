# PhoneBox host protocol (what the iPad shell must do)

Measured from the Android shell (`android/app/src/main/java/net/oxog/phonebox/deskpanel/`: `MainActivity.kt`,
`AgentLink.kt`, `AgentStream.kt`) and the agent (`agent/PhoneBox.Agent/Program.cs`, `Lan.cs`, `Pairing.cs`) at
upstream commit 211a5f0. The iPad app reproduces the **Wi-Fi route only**; the USB route (adb reverse to
`https://127.0.0.1:8765`, key read over adb) does not exist on iPad.

Result: **no agent change is needed.** Everything below already works for any client that pins the certificate and
sends the key.

## 1. Pairing (QR code, no USB)

The agent's settings page (Settings › Wi-Fi › "Pair a phone or iPad over Wi-Fi", local only: `POST /api/pair/start`) shows a QR
code holding:

```
https://ersinkoc.github.io/phonebox/pair/#v=1&pc=<name>&fp=<sha256 hex>&port=<port>&h=<ip>,<ip>&c=<one-time code>
```

* Everything is in the URL **fragment**, so a browser never sends it to github.io.
* `fp`: lowercase hex SHA-256 of the agent's DER certificate (64 chars). This is the computer's id and the pin.
* `h`: comma separated IPv4 addresses. Only private (10/8, 172.16/12, 192.168/16) and Tailscale (100.64/10) are accepted;
  at most 8.
* `c`: one-time code, `[A-Za-z0-9_-]{16,64}`, valid once for 5 minutes, dropped after 10 wrong tries.
* `pc`: computer name (display only, max 64 chars).
* Check code shown on both screens: first 8 hex chars of `fp`, upper case, as `ABCD EF12`.

The github.io page (`tools/pages/pair.html`) offers `phonebox://pair?<same query>` on non-Android browsers, so on the
iPad, scanning with the Camera app → Safari → "Open in PhoneBox" lands in the app through the `phonebox` URL scheme.
The app also accepts the https link directly (in-app QR scanner).

Claim:

```
POST https://<host>:<port>/api/pair/claim         (try each host in order)
TLS: pinned to fp (see §3); no Authorization header
Content-Type: application/json
X-PhoneBox-Model: <model>
{"code":"<c>"}
```

* 200 → `{"enabled":true,"pc","port","token","fingerprint","hosts":[…],"macs":[…]}`. Reject if `fingerprint` ≠ `fp`.
  Store `{id: fp, name: pc-from-link, hosts (filtered, fallback to link's), port, token, macs}` and make it active.
* 403 → code refused (used, expired or wrong). Stop, do not try other hosts.
* TLS failure → wrong certificate. Other errors → try next host.

The agent also lets the pairing claim through only when Wi-Fi is enabled in its settings (General › Wi-Fi & Tailscale
› "Let the phone connect without the USB cable"), and caps the body at 1 KB.

## 2. Every request to the agent

```
https://<host>:<port><path>?<query>
Authorization: Bearer <token>
X-PhoneBox-App: <app version>        (marks a phone: approvals, "phone connected", stream logging)
X-PhoneBox-Device: <id>              ([A-Za-z0-9]{1,32}; per-device pages in Settings › Phones)
X-PhoneBox-Model: <model>            (printable ASCII, ≤40)
X-PhoneBox-WebView: <pkg/version>    (optional; Android WebView diagnostics, iPad omits it)
```

* No `Origin` header (the LAN port refuses any request with a non-empty Origin). URLSession sends none.
* Only the paths in `Lan.AllowedOverLan` are served on the Wi-Fi port; everything else is 403.
* Try the hosts in order, starting with the one that worked last; connect timeout 1.5 s, read timeout 4 s
  (30 s for POST).
* **A POST must never be retried on another host once its request was sent** (macros, toggles). If the response
  is lost, answer 504 `{"ok":false,"error":"The command result is unknown; check the computer before retrying"}`.
* Redirects are not followed; a 3xx becomes 502. No host answers → 503 `{"error":"offline"}`.
* `X-PhoneBox-App`: the agent stores it as "the phone app's version" and offers APK updates when it is older than
  the latest release (`UpdateService.Newer`). The iPad sends `ipad-<version>`, which does not parse as a version,
  so it never triggers an APK offer. (It does overwrite the stored value while an Android phone is also in use.)

## 3. Certificate pinning

Android installs an `X509TrustManager` that accepts the chain only when `SHA-256(chain[0].encoded)` equals the stored
`fp`, and disables host name checks (the certificate, not the address, is the identity). The agent's certificate is a
self-signed ECDSA P-256 cert, `CN=PhoneBox agent (<machine>)`, valid 20 years, stored in `lan-cert.pfx`.

iPad: `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)` for `NSURLAuthenticationMethodServerTrust`:
take the leaf of `SecTrustCopyCertificateChain`, hash `SecCertificateCopyData` with SHA-256, compare to the pin,
then `.useCredential` with `URLCredential(trust:)`; otherwise `.cancelAuthenticationChallenge`.

## 4. The panel ↔ host contract

* The panel is loaded from the app bundle (Android: `https://appassets.androidplatform.net/assets/www/index.html`).
* Requests to `/agent/<rest>` are proxied to the agent as `<rest>` (`/agent/api/state` → `/api/state`), method and
  query kept. Every panel `POST` carries its arguments in the query string, never a body (Android's
  `shouldInterceptRequest` cannot read bodies), so a bodyless proxy is enough.
* Only the panel may use the proxy: a request must carry `X-PhoneBox-Panel`, or be a `GET` of one of the read-only
  image paths: `/agent/api/art`, `/agent/api/procs/icon`, `/agent/api/controls/radio-logo`, `/agent/api/apps/icon`,
  `/agent/api/discord/img`, `/agent/api/shortcuts/icon`, `/agent/api/steam/cover`, `/agent/api/wallpaper`.
  Anything else → 403 (keeps the sandboxed Custom HTML iframe away from the agent).
* Responses get `Cache-Control: no-store`. JS modules must be served as `text/javascript`.

### Live stream

`GET /api/stream` (server-sent events, `event:` / `data:` lines, blank line ends an event). The agent sends `state`
every second, `event` when one happens, `work` and `spectrum` on change. The host:

* calls `window.onAgentStream('open', '{"route":"wifi"}')` once connected, then
  `window.onAgentStream(<event>, <data JSON string>)` for each event, and `('close','{}')` when it ends;
* treats 8 s of silence as a dead connection; reconnects after 300 ms (was open) or 2 s (never opened);
* on Wi-Fi, closes and reopens the stream every 60 s (Android does this so USB can win again; harmless on iPad);
* stops the stream when the app is not visible.

### Visibility

`window.onAppPause(true)` when the panel is hidden (background, screen off), `onAppPause(false)` when it is back.

### Native bridge: `window.Android`

The panel (`main.js`, `BRIDGE`) calls `Android[method](window.__phoneboxKey, ...args)` **synchronously** and uses the
return value of: `battery` (JSON string), `is24Hour` (bool), `pcs` (JSON string), `transport` (string), `sensors`
(JSON string), `version` (string), `canListen` (bool), `listen` (int), `canWake` (bool), `wakePc` (bool). Every
method is optional; `bridge === null` when `window.Android` is absent.

WKWebView has no synchronous native calls, so the iPad shell injects a JavaScript `window.Android` object (main frame
only, at document start) whose getters return a snapshot the app pushes (`window.__phoneboxHost`) and whose actions
post to a `WKScriptMessageHandler`. The handler also checks `message.frameInfo.isMainFrame` and the key.

| Method | Android | iPad |
| --- | --- | --- |
| `battery()` | level, plugged, temp, source, usb | level, plugged, source `ac`/`""`, temp 0 |
| `buzz(pattern)` / `haptic()` | vibrator | no-op (no vibration motor) |
| `is24Hour()` | system setting | `DateFormatter` locale check |
| `pcs()` / `selectPc(id)` / `forgetPc(id)` | paired list | same, Keychain |
| `setBrightness(v)` | window brightness, <0 = system | `UIScreen.brightness`, <0 restores the value at launch |
| `setOrientation(m)` | landscape / portrait / auto | `requestGeometryUpdate` + supported orientations |
| `setPinned(on)` | screen pinning | no-op (use Single App Mode / Guided Access) |
| `setHomeScreen(on)` | home launcher alias | no-op |
| `setVolumeKeys(on)` | volume keys flip pages | no-op (iOS gives apps no volume key events) |
| `setStandby(mode, grace)` | release keep-awake when the PC is gone | black cover + lowest backlight after the grace period, back by itself (an app cannot wake a locked iPad), a tap shows the panel for 30 s |
| `setLanguage(tag)` | remembers for pairing dialogs | stored only |
| `transport()` | `usb` / `wifi` / `none` | `wifi` / `none` |
| `sensors()` | light, proximity | `{"light":false,"proximity":false}` (no public API) |
| `version()` | versionName | `CFBundleShortVersionString` |
| `canListen/listen/stopListening/cancelListening` | Android speech | `SFSpeechRecognizer`; the shim numbers the sessions so `listen` can answer at once; 2 s of quiet after speech ends a session |
| `trackpad(type,dx,dy,delta)` | WebSocket, else coalesced POST | coalesced `POST /api/trackpad` JSON |
| `canWake()` / `wakePc(id)` | Wake-on-LAN broadcast | `false` (UDP broadcast needs Apple's multicast entitlement) |

Callbacks the panel defines and the host may call: `onAgentStream`, `onAppPause`, `onAndroidKey('prev'|'next')`
(hardware keyboard arrows also work in the page itself), `onAndroidBack()`, `onAndroidSensor(kind, value)`,
`onAndroidSpeech(kind, text, id)`.

## 5. Known panel quirks on a non-Android host

* `widgets/controls.js` (trackpad) opens `ws(s)://<location.host>/api/trackpad` unless the host name contains
  `androidplatform.net`. Under the iPad's custom scheme that socket just fails and the widget falls back to
  `bridge.trackpad`, retrying the socket every 2 s. Harmless; a one-line panel change can skip it later.
* The panel reports its battery with `POST /api/phone/battery`, which feeds the agent's charge guard. If the charge
  guard is set up for an Android phone, the iPad's reports will also reach it.

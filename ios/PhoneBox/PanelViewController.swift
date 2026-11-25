import UIKit
import WebKit

/// Full-screen desk panel: the PhoneBox panel (plain HTML/JS, bundled) in a WKWebView, its /agent/* requests forwarded
/// to the agent over Wi-Fi, the live stream, and the native bridge. Port of MainActivity.kt (Wi-Fi route).
final class PanelViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {

    private let link = AgentLink()
    private lazy var trackpad = TrackpadSender(link: link)
    private lazy var schemeHandler = PanelSchemeHandler(link: link)
    private lazy var stream = AgentStream(link: link) { [weak self] event, data in
        guard let self else { return }
        if event == "open" || event == "close" { self.pushHostState() }
        self.callPanel("window.onAgentStream && window.onAgentStream(\(Bridge.jsString(event)), \(Bridge.jsString(data)))")
    }
    private var web: WKWebView!
    private let bridgeKey = UUID().uuidString
    private var visible = false
    private var hostStateTimer: Timer?
    private var orientationMask: UIInterfaceOrientationMask = .landscape
    private var launchBrightness: CGFloat?
    private let pairingBanner = UIButton(type: .system)

    private let defaults = UserDefaults.standard

    // MARK: - kiosk chrome

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // swipes from the edges go to the panel first; a second swipe still reaches the system
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        orientationMask = Self.mask(for: defaults.string(forKey: "orientation") ?? "landscape")

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: PanelSchemeHandler.scheme)
        config.websiteDataStore = .default() // the panel keeps small settings in localStorage
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakMessageHandler(self), name: Bridge.handlerName)

        web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        #if DEBUG
        web.isInspectable = true // Safari on the Mac › Develop › <iPad> › PhoneBox
        #endif
        view.addSubview(web)

        schemeHandler.onAgentAnswer = { [weak self] in self?.noteAgentAnswer() }

        setUpPairingBanner()
        // three fingers held for a second: the app's own menu (pair, computers, reload) in a kiosk with no other chrome
        let menu = UILongPressGestureRecognizer(target: self, action: #selector(showAppMenu(_:)))
        menu.numberOfTouchesRequired = 3
        menu.minimumPressDuration = 1.0
        menu.cancelsTouchesInView = false
        view.addGestureRecognizer(menu)

        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged),
                                               name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(batteryChanged),
                                               name: UIDevice.batteryStateDidChangeNotification, object: nil)

        loadPanel()
    }

    // MARK: - panel

    private func hostSnapshot() -> String {
        let device = UIDevice.current
        let level = device.batteryLevel < 0 ? -1 : Int((device.batteryLevel * 100).rounded())
        let plugged = device.batteryState == .charging || device.batteryState == .full
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "HH"
        let snapshot: [String: Any] = [
            "battery": ["level": level, "plugged": plugged, "temp": 0, "source": plugged ? "ac" : "", "usb": NSNull()],
            "is24Hour": !format.contains("a"),
            "pcs": link.pcsJSON(),
            "transport": link.route.rawValue,
            "version": HostInfo.appVersion,
        ]
        return Bridge.json(snapshot)
    }

    /// (Re)loads the panel with a fresh bootstrap script (the key and the host snapshot at document start).
    private func loadPanel() {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        let script = Bridge.bootstrapScript(key: bridgeKey, languages: Locale.preferredLanguages, snapshot: hostSnapshot())
        // main frame only: the sandboxed iframe of a Custom HTML widget never sees the key or window.Android
        ucc.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.load(URLRequest(url: PanelSchemeHandler.startURL))
        updatePairingBanner()
    }

    private func callPanel(_ js: String) {
        web?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func pushHostState() {
        callPanel("window.__phoneboxHost = \(hostSnapshot());")
    }

    @objc private func batteryChanged() { pushHostState() }

    private func noteAgentAnswer() {
        // standby (release the screen when the computer is gone) is phase 2; for now every answer is just a sign of life
    }

    /// Called by the scene: the panel can (not) be seen. Android: onResume / onPause.
    func setVisible(_ on: Bool) {
        guard isViewLoaded, on != visible else { return }
        visible = on
        UIApplication.shared.isIdleTimerDisabled = on // keep the screen on while the panel shows
        if on {
            callPanel("window.onAppPause && window.onAppPause(false)") // the panel catches up at once
            stream.start()
            pushHostState()
            hostStateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.pushHostState() }
        } else {
            hostStateTimer?.invalidate()
            hostStateTimer = nil
            stream.stop()
            callPanel("window.onAppPause && window.onAppPause(true)")
        }
    }

    // MARK: - bridge actions

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // the panel's own frame only, and only with this run's key (Bridge.bootstrapScript)
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == PanelSchemeHandler.scheme,
              let body = message.body as? [String: Any], body["key"] as? String == bridgeKey,
              let method = body["m"] as? String else { return }
        let args = body["args"] as? [Any] ?? []
        switch method {
        case "selectPc":
            guard let id = args.first as? String, link.select(id) else { return }
            stream.stop()
            loadPanel()
            if visible { stream.start() }
        case "forgetPc":
            guard let id = args.first as? String else { return }
            link.forget(id)
            pushHostState()
            updatePairingBanner()
        case "setBrightness":
            guard let value = (args.first as? NSNumber)?.doubleValue, let screen = view.window?.windowScene?.screen else { return }
            if value < 0 {
                if let b = launchBrightness { screen.brightness = b; launchBrightness = nil } // back to the user's setting
            } else {
                if launchBrightness == nil { launchBrightness = screen.brightness }
                screen.brightness = CGFloat(min(max(value, 0.01), 1))
            }
        case "setOrientation":
            let mode = args.first as? String ?? "landscape"
            defaults.set(mode, forKey: "orientation")
            applyOrientation(Self.mask(for: mode))
        case "setLanguage":
            if let tag = args.first as? String { defaults.set(tag, forKey: "language") }
        case "setStandby":
            if let mode = args.first as? String { defaults.set(mode, forKey: "standby") } // phase 2
        case "trackpad":
            guard args.count == 4, let type = args[0] as? String else { return }
            let n = args.dropFirst().map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            let sender = trackpad
            Task { await sender.send(type: type, dx: n[0], dy: n[1], delta: n[2]) }
        default:
            break
        }
    }

    private static func mask(for mode: String) -> UIInterfaceOrientationMask {
        switch mode {
        case "portrait": return [.portrait, .portraitUpsideDown]
        case "auto": return .all
        default: return .landscape
        }
    }

    private func applyOrientation(_ mask: UIInterfaceOrientationMask) {
        guard mask != orientationMask else { return }
        orientationMask = mask
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    // MARK: - navigation

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // the main frame stays on the panel; widgets' own iframes may load what they load
        if action.targetFrame?.isMainFrame == true, let scheme = action.request.url?.scheme,
           scheme != PanelSchemeHandler.scheme, scheme != "about" {
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushHostState()
        if !visible { callPanel("window.onAppPause && window.onAppPause(true)") }
    }

    /// WebKit's content process died (memory pressure on a 3 GB iPad): start the panel again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPanel()
    }

    // MARK: - pairing

    func handlePairingURL(_ url: URL) {
        loadViewIfNeeded()
        guard let pairing = PairLink.parse(url) else {
            if url.scheme == "phonebox" { alert("Not a pairing link", "Show the QR code again in the PhoneBox settings on the computer.") }
            return
        }
        let ask = UIAlertController(title: "Pair with \(pairing.pc)?",
            message: "Addresses: \(pairing.hosts.joined(separator: ", ")), port \(pairing.port).\n\nCheck code: \(pairing.check)\n\nPair only if the computer shows the same check code next to its QR code.",
            preferredStyle: .alert)
        ask.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        ask.addAction(UIAlertAction(title: "Pair", style: .default) { [weak self] _ in self?.pair(pairing) })
        present(ask, animated: true)
    }

    private func pair(_ pairing: PairLink) {
        let link = self.link
        Task {
            let problem = await link.claim(pairing)
            await MainActor.run {
                if let problem {
                    self.alert("Pairing failed", problem.message)
                } else {
                    self.stream.stop()
                    self.loadPanel()
                    if self.visible { self.stream.start() }
                    self.alert("Paired", "This iPad now shows \(pairing.pc).")
                }
            }
        }
    }

    private func scanQRCode() {
        let scanner = QRScannerViewController { [weak self] text in
            guard let self else { return }
            self.dismiss(animated: true) {
                if let url = URL(string: text) { self.handlePairingURL(url) }
            }
        }
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    private func setUpPairingBanner() {
        var config = UIButton.Configuration.filled()
        config.title = "Not paired: scan the pairing QR code"
        config.subtitle = "On the computer: PhoneBox settings › Wi-Fi › Pair a phone over Wi-Fi"
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)
        pairingBanner.configuration = config
        pairingBanner.addAction(UIAction { [weak self] _ in self?.scanQRCode() }, for: .primaryActionTriggered)
        pairingBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pairingBanner)
        NSLayoutConstraint.activate([
            pairingBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pairingBanner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    private func updatePairingBanner() {
        pairingBanner.isHidden = link.store.active != nil
    }

    @objc private func showAppMenu(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, presentedViewController == nil else { return }
        let menu = UIAlertController(title: "PhoneBox \(HostInfo.appVersion)", message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "Scan a pairing QR code", style: .default) { [weak self] _ in self?.scanQRCode() })
        for pc in link.store.all {
            let active = pc.id == link.store.active?.id
            menu.addAction(UIAlertAction(title: (active ? "✓ " : "") + pc.name, style: .default) { [weak self] _ in
                guard let self, !active, self.link.select(pc.id) else { return }
                self.stream.stop(); self.loadPanel(); if self.visible { self.stream.start() }
            })
        }
        if let active = link.store.active {
            menu.addAction(UIAlertAction(title: "Forget \(active.name)", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.link.forget(active.id)
                self.stream.stop(); self.loadPanel(); if self.visible { self.stream.start() }
            })
        }
        menu.addAction(UIAlertAction(title: "Reload panel", style: .default) { [weak self] _ in self?.loadPanel() })
        menu.addAction(UIAlertAction(title: "Close", style: .cancel))
        if let pop = menu.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(origin: gesture.location(in: view), size: .zero)
        }
        present(menu, animated: true)
    }

    private func alert(_ title: String, _ message: String) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        if let presented = presentedViewController { presented.present(a, animated: true) } else { present(a, animated: true) }
    }
}

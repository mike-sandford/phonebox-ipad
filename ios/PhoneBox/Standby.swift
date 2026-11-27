import UIKit

/// Standby (Settings › Display › Standby on the computer): darken the panel while the computer is gone, and light it
/// again by itself when the computer is back. Port of MainActivity's power standby, with one difference: Android lets
/// the phone sleep and wakes it later, but an iPad app cannot switch the display back on once the iPad has locked. So
/// the iPad stays awake behind a black cover with the backlight at its lowest, which is what lets the panel come back
/// on its own. A tap shows the panel for a short while.
///
/// Modes, as the agent sends them: "off" (always lit, the default), "power" (dark while the iPad is not charging),
/// "data" (dark while the agent does not answer). Either way only after the grace period, so a Mac restart or a
/// Wi-Fi hiccup does not black the panel.
@MainActor
final class Standby: NSObject {
    // this long with no answer at all => the agent is not reachable. The live stream brings a state every second, so a
    // few seconds is plenty; the grace period (the agent's setting) is what absorbs a restart or a Wi-Fi hiccup.
    private static let silence: TimeInterval = 5
    private static let tickEvery: TimeInterval = 2
    private static let peekFor: TimeInterval = 30 // a tap on the dark screen shows the panel this long

    private(set) var mode = "off"
    private var grace: TimeInterval = 30
    private var lastAnswer = ProcessInfo.processInfo.systemUptime
    private var lostSince: TimeInterval = 0
    private var peekUntil: TimeInterval = 0
    private(set) var asleep = false
    private var running = false
    private var timer: Timer?
    /// The brightness to come back to (the panel may set a new one while the screen is dark).
    private var wakeBrightness: CGFloat?

    private let cover = UIView()
    private weak var host: UIView?
    /// Whether there is a paired computer at all: without one the "not paired" banner must stay visible.
    private let isPaired: () -> Bool
    private let defaults = UserDefaults.standard

    init(isPaired: @escaping () -> Bool) {
        self.isPaired = isPaired
        mode = UserDefaults.standard.string(forKey: "standby") ?? "off"
        let saved = UserDefaults.standard.integer(forKey: "standbyGrace")
        grace = saved > 0 ? TimeInterval(saved) : 30
        super.init()
        // the backlight is the iPad's to change (Control Center): while dark, standby puts it back to its lowest
        NotificationCenter.default.addObserver(self, selector: #selector(brightnessChanged),
                                               name: UIScreen.brightnessDidChangeNotification, object: nil)
        cover.backgroundColor = .black
        cover.isHidden = true
        cover.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(peek)))
    }

    /// Puts the (hidden) black cover above everything in [view].
    func attach(to view: UIView) {
        host = view
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cover)
    }

    /// The agent's display.standby setting, from the panel (bridge setStandby).
    func configure(mode newMode: String, graceSeconds: Int) {
        let m = ["power", "data"].contains(newMode) ? newMode : "off"
        let g = TimeInterval(min(max(graceSeconds, 5), 3600))
        guard m != mode || g != grace else { return }
        mode = m
        grace = g
        defaults.set(m, forKey: "standby")
        defaults.set(Int(g), forKey: "standbyGrace")
        restart()
    }

    /// The agent answered (a panel request, or the live stream): the computer is there.
    func noteAnswer() {
        lastAnswer = ProcessInfo.processInfo.systemUptime
        if asleep { tick() }
    }

    /// The panel can (not) be seen. Hidden, nothing is watched and the screen is left as it was before standby.
    func setRunning(_ on: Bool) {
        running = on
        restart()
    }

    /// Sets the screen brightness, or the brightness to come back to while the screen is dark.
    func setBrightness(_ value: CGFloat, on screen: UIScreen) {
        if asleep { wakeBrightness = value } else { screen.brightness = value }
    }

    /// For the app menu: what standby does now, so a setting that never arrived is easy to tell apart from a slow one.
    var summary: String {
        switch mode {
        case "data", "power":
            let what = mode == "data" ? "when the Mac stops answering" : "when the iPad is not charging"
            var s = "Standby: dark \(what), after \(Int(grace)) s."
            let now = ProcessInfo.processInfo.systemUptime
            if mode == "data" { s += " Last answer \(Int(now - lastAnswer)) s ago." }
            if lostSince > 0 { s += " Gone for \(Int(now - lostSince)) s." }
            return s
        default:
            return "Standby: off (PhoneBox settings on the Mac › Display › Standby)."
        }
    }

    /// The brightness the screen has, or comes back to while it is dark.
    func brightness(of screen: UIScreen) -> CGFloat { asleep ? (wakeBrightness ?? screen.brightness) : screen.brightness }

    private func restart() {
        timer?.invalidate()
        timer = nil
        wake()
        lostSince = 0
        peekUntil = 0
        lastAnswer = ProcessInfo.processInfo.systemUptime // give the agent a full silence window after a change
        guard running, mode != "off" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard running, mode != "off" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let absent: Bool
        switch mode {
        case "power":
            let state = UIDevice.current.batteryState
            absent = state == .unplugged // .unknown (battery monitoring off) never counts as gone
        default:
            absent = now - lastAnswer >= Self.silence
        }
        guard absent, isPaired() else {
            lostSince = 0
            peekUntil = 0
            wake()
            return
        }
        if lostSince == 0 { lostSince = now; return }
        if !asleep, now - lostSince >= grace, now >= peekUntil { sleep() }
    }

    private func sleep() {
        guard !asleep, let screen = host?.window?.windowScene?.screen else { return }
        asleep = true
        wakeBrightness = screen.brightness
        screen.brightness = 0
        host?.bringSubviewToFront(cover)
        cover.isHidden = false
    }

    private func wake() {
        guard asleep else { return }
        asleep = false
        cover.isHidden = true
        if let b = wakeBrightness, let screen = host?.window?.windowScene?.screen { screen.brightness = b }
        wakeBrightness = nil
    }

    @objc private func brightnessChanged(_ note: Notification) {
        guard asleep, let screen = note.object as? UIScreen ?? host?.window?.windowScene?.screen, screen.brightness > 0 else { return }
        screen.brightness = 0
    }

    @objc private func peek() {
        peekUntil = ProcessInfo.processInfo.systemUptime + Self.peekFor
        wake()
    }
}

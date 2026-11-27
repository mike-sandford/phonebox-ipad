import Foundation

/// What the app tells the agent about itself (AgentLink sends it on every request, as the Android app does).
enum HostInfo {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// X-PhoneBox-App. "ipad-<version>" marks a phone for the agent (approvals, "phone connected") but does not parse as
    /// a version, so the agent never offers this device an Android APK update (UpdateService.Newer).
    static let appHeader = "ipad-" + appVersion

    /// X-PhoneBox-Device: 12 hex chars, random once per install. The agent keys per-device pages on it.
    static let deviceId: String = {
        let key = "deviceId"
        if let id = UserDefaults.standard.string(forKey: key), id.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil {
            return id
        }
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// X-PhoneBox-Model: "Apple iPad7,11" (the hardware model), printable ASCII, at most 40 characters.
    static let model: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let text = "Apple " + (machine.isEmpty ? "iPad" : machine)
        return String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }.map(Character.init).prefix(40))
    }()
}

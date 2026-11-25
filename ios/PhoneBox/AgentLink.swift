import CryptoKit
import Foundation

/// Connection to the PhoneBox agent on the computer, over Wi-Fi (or Tailscale) only. Port of the Android app's
/// AgentLink.kt Wi-Fi route; see ios/PROTOCOL.md.
///
/// Every request goes to https://<pc-address>:<port>, trusts only the certificate whose SHA-256 is the paired
/// fingerprint (pinning) and carries the paired key. Each paired computer is remembered; one is active.
final class AgentLink: @unchecked Sendable {

    struct Reply {
        let status: Int
        let contentType: String?
        let body: Data

        static let offline = Reply(status: 503, contentType: "application/json", body: Data(#"{"error":"offline"}"#.utf8))
        static let unknownResult = Reply(status: 504, contentType: "application/json",
            body: Data(#"{"ok":false,"error":"The command result is unknown; check the computer before retrying"}"#.utf8))
        static let unexpected = Reply(status: 502, contentType: "application/json", body: Data(#"{"error":"unexpected response"}"#.utf8))
    }

    enum Route: String { case wifi, none }

    let store = PcStore()
    private let lock = NSLock()
    private var _route: Route = .none
    private var preferredHost = 0
    private var pinned: (pin: String, session: URLSession)?

    /// How the last agent request was delivered ("wifi" / "none"), for the panel's bridge.transport().
    var route: Route {
        lock.lock(); defer { lock.unlock() }
        return _route
    }

    private func setRoute(_ r: Route) {
        lock.lock(); _route = r; lock.unlock()
    }

    /// One URLSession per pinned certificate, so HTTPS connections are kept alive between requests.
    private func session(for pin: String) -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let p = pinned, p.pin == pin { return p.session }
        pinned?.session.finishTasksAndInvalidate()
        let s = Self.makeSession(pin: pin)
        pinned = (pin, s)
        return s
    }

    static func makeSession(pin: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config, delegate: PinnedDelegate(pin: pin), delegateQueue: nil)
    }

    // MARK: - paired computers

    /// The paired computers for the panel: [{"id", "name", "active"}].
    func pcsJSON() -> [[String: Any]] {
        let active = store.active?.id
        return store.all.map { ["id": $0.id, "name": $0.name, "active": $0.id == active] }
    }

    func select(_ id: String) -> Bool {
        guard store.select(id) else { return false }
        lock.lock(); preferredHost = 0; lock.unlock()
        return true
    }

    func forget(_ id: String) { store.forget(id) }

    // MARK: - requests

    private func hostOrder(_ pc: Pc) -> [Int] {
        lock.lock(); let preferred = preferredHost; lock.unlock()
        return pc.hosts.indices.sorted { a, b in
            (a == preferred ? -1 : a) < (b == preferred ? -1 : b)
        }
    }

    private func makeRequest(_ pc: Pc, host: String, method: String, pathAndQuery: String, timeout: TimeInterval) -> URLRequest? {
        guard let url = URL(string: "https://\(host):\(pc.port)\(pathAndQuery)") else { return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(pc.token)", forHTTPHeaderField: "Authorization")
        req.setValue(HostInfo.appHeader, forHTTPHeaderField: "X-PhoneBox-App")
        req.setValue(HostInfo.deviceId, forHTTPHeaderField: "X-PhoneBox-Device")
        req.setValue(HostInfo.model, forHTTPHeaderField: "X-PhoneBox-Model")
        return req
    }

    /// Errors after which the request certainly never reached the agent, so another address may be tried even for a POST.
    private static func notSent(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .cancelled,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL:
            return true
        default:
            return false
        }
    }

    /// Forwards a request (method + path with query) to the active computer, trying its addresses in turn.
    func request(method: String, pathAndQuery: String, body: Data? = nil, contentType: String? = nil) async -> Reply {
        guard let pc = store.active, !pc.hosts.isEmpty else { setRoute(.none); return .offline }
        let session = session(for: pc.id)
        // every POST acts on the computer (a container restart, a Home Assistant switch, a macro): none may run twice
        let controlPost = method == "POST"
        for i in hostOrder(pc) {
            guard var req = makeRequest(pc, host: pc.hosts[i], method: method, pathAndQuery: pathAndQuery,
                                        timeout: controlPost ? 30 : 4) else { continue }
            if controlPost {
                req.httpBody = body ?? Data()
                if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else { return .unexpected }
                lock.lock(); if store.active?.id == pc.id { preferredHost = i }; lock.unlock()
                setRoute(.wifi)
                if !(100...599).contains(http.statusCode) || (300...399).contains(http.statusCode) { return .unexpected }
                return Reply(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
            } catch {
                // The command may already have reached the agent: trying another address could run it twice.
                if controlPost && !Self.notSent(error) { return .unknownResult }
            }
        }
        setRoute(.none)
        return .offline
    }

    /// Opens the live stream (/api/stream, server-sent events) on the active computer; nil when it is unreachable.
    /// The agent sends "state" every second, so 8 s without a byte means the connection is dead.
    func openStream() async -> URLSession.AsyncBytes? {
        guard let pc = store.active, !pc.hosts.isEmpty else { return nil }
        let session = session(for: pc.id)
        for i in hostOrder(pc) {
            guard let req = makeRequest(pc, host: pc.hosts[i], method: "GET", pathAndQuery: "/api/stream", timeout: 8) else { continue }
            do {
                let (bytes, response) = try await session.bytes(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { bytes.task.cancel(); continue }
                lock.lock(); if store.active?.id == pc.id { preferredHost = i }; lock.unlock()
                setRoute(.wifi)
                return bytes
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - pairing

    /// Why a pairing failed (AgentLink.PairFailure on Android).
    enum PairFailure {
        case unreachable(pc: String, hosts: [String])
        case codeRejected(pc: String)
        case badAnswer(pc: String, status: Int)
        case wrongCertificate(pc: String)

        var message: String {
            switch self {
            case let .unreachable(pc, hosts):
                return "\(pc) did not answer at \(hosts.joined(separator: ", ")). Is the iPad on the same network, and is Wi-Fi turned on in the PhoneBox settings? A firewall may also be blocking PhoneBox."
            case let .codeRejected(pc):
                return "\(pc) refused the pairing code. A code works once, for five minutes: show a new QR code on the computer and scan it again."
            case let .badAnswer(pc, status):
                return "\(pc) gave an unexpected answer (HTTP \(status)). Update the PhoneBox agent and try again."
            case .wrongCertificate:
                return "The computer that answered is not the one in the QR code (its certificate is different). Nothing was sent to it."
            }
        }
    }

    private static let certificateErrors: [URLError.Code] = [.cancelled, .serverCertificateUntrusted,
                                                              .secureConnectionFailed, .serverCertificateHasUnknownRoot]

    /// Trades the link's one-time code for the Wi-Fi key and makes that computer the active one. nil when paired.
    func claim(_ link: PairLink) async -> PairFailure? {
        let session = Self.makeSession(pin: link.fingerprint)
        defer { session.finishTasksAndInvalidate() }
        var problem = PairFailure.unreachable(pc: link.pc, hosts: link.hosts)
        for host in link.hosts {
            guard let url = URL(string: "https://\(host):\(link.port)/api/pair/claim") else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(HostInfo.model, forHTTPHeaderField: "X-PhoneBox-Model")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": link.code])
            do {
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 403 { return .codeRejected(pc: link.pc) }
                guard status == 200 else { problem = .badAnswer(pc: link.pc, status: status); continue }
                guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = j["token"] as? String, !token.isEmpty else {
                    problem = .badAnswer(pc: link.pc, status: status); continue
                }
                guard (j["fingerprint"] as? String)?.lowercased() == link.fingerprint else { return .wrongCertificate(pc: link.pc) }
                let reported = (j["hosts"] as? [String] ?? []).filter(PairLink.isLocalAddress)
                let macs = j["macs"] as? [String]
                let id = link.fingerprint
                let pc = Pc(id: id, name: link.pc, hosts: reported.isEmpty ? link.hosts : reported,
                            port: (j["port"] as? Int) ?? link.port, token: token,
                            macs: macs ?? store.all.first { $0.id == id }?.macs ?? [])
                store.upsert(pc)
                lock.lock(); preferredHost = 0; lock.unlock()
                return nil
            } catch let e as URLError where Self.certificateErrors.contains(e.code) {
                problem = .wrongCertificate(pc: link.pc)
            } catch {
                // try the next address
            }
        }
        return problem
    }
}

/// Trusts only the certificate whose SHA-256 (of its DER encoding) is the pin; the host name is not checked, because
/// the pinned certificate, not the address, is the computer's identity. Redirects are never followed.
final class PinnedDelegate: NSObject, URLSessionTaskDelegate {
    private let pin: String

    init(pin: String) { self.pin = pin.lowercased() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if fingerprint == pin {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Pairing link from the computer's QR code: https://ersinkoc.github.io/phonebox/pair/#v=1&... (data in the fragment)
/// or phonebox://pair?v=1&... (the "Open in PhoneBox" button on that page).
struct PairLink {
    let pc: String
    let fingerprint: String
    let port: Int
    let hosts: [String]
    let code: String

    /// Shown on the computer next to the QR code and in the iPad's confirmation: "ABCD EF12".
    var check: String {
        let head = fingerprint.prefix(8).uppercased()
        return head.count == 8 ? "\(head.prefix(4)) \(head.suffix(4))" : head
    }

    /// Private network (10/8, 172.16/12, 192.168/16) and Tailscale (100.64/10) IPv4 only.
    static func isLocalAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var b: [Int] = []
        for p in parts {
            guard (1...3).contains(p.count), p.allSatisfy(\.isASCII), let v = Int(p), (0...255).contains(v) else { return false }
            b.append(v)
        }
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 100 && (64...127).contains(b[1]))
    }

    static func parse(_ url: URL) -> PairLink? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let raw: String?
        if parts.scheme == "https" && parts.host == "ersinkoc.github.io" && parts.path.hasPrefix("/phonebox/pair") {
            raw = parts.percentEncodedFragment
        } else if parts.scheme == "phonebox" && parts.host == "pair" {
            raw = parts.percentEncodedQuery
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        var q: [String: String] = [:]
        for part in raw.split(separator: "&") {
            guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { continue }
            let key = String(part[..<eq])
            let value = String(part[part.index(after: eq)...])
            q[key] = value.removingPercentEncoding ?? value
        }
        guard q["v"] == "1",
              let fp = q["fp"]?.lowercased(), fp.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let port = q["port"].flatMap({ Int($0) }), (1...65535).contains(port),
              let code = q["c"], code.range(of: "^[A-Za-z0-9_-]{16,64}$", options: .regularExpression) != nil
        else { return nil }
        let hosts = (q["h"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter(isLocalAddress).prefix(8)
        guard !hosts.isEmpty else { return nil }
        let name = String((q["pc"] ?? "").unicodeScalars.filter { $0.value >= 0x20 }.map(Character.init).prefix(64))
            .trimmingCharacters(in: .whitespaces)
        return PairLink(pc: name.isEmpty ? "your computer" : name, fingerprint: fp, port: port, hosts: Array(hosts), code: code)
    }
}

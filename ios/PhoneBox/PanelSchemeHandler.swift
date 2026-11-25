import Foundation
import WebKit

/// Serves the panel at pbpanel://app/ from the bundled www folder (copied from the Android app at build time) and
/// forwards pbpanel://app/agent/... to the agent, like MainActivity.shouldInterceptRequest on Android. The web view
/// itself never talks to the network, so there is no CORS, mixed content or certificate prompt.
final class PanelSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pbpanel"
    static let startURL = URL(string: "pbpanel://app/index.html")!

    /// Image GETs that cannot carry the panel header but only read (MainActivity.READ_ONLY_IMAGES).
    private static let readOnlyImages: Set<String> = ["/agent/api/art", "/agent/api/procs/icon", "/agent/api/controls/radio-logo",
        "/agent/api/apps/icon", "/agent/api/discord/img", "/agent/api/shortcuts/icon", "/agent/api/steam/cover", "/agent/api/wallpaper"]

    private let link: AgentLink
    private let www: URL
    /// Called on the main thread when the agent answered (status < 400): a sign of life.
    var onAgentAnswer: (() -> Void)?
    /// Tasks WebKit has not stopped yet (main thread only): calling a stopped task raises an exception.
    private var live = Set<ObjectIdentifier>()

    init(link: AgentLink) {
        self.link = link
        self.www = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("www", isDirectory: true).standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task as AnyObject)
        live.insert(id)
        guard let url = task.request.url else { finish(task, status: 400, type: "text/plain", body: Data()); return }
        let path = url.path(percentEncoded: true)
        if path.hasPrefix("/agent/") {
            let method = task.request.httpMethod ?? "GET"
            let fromPanel = task.request.value(forHTTPHeaderField: "X-PhoneBox-Panel") != nil
                || (method == "GET" && Self.readOnlyImages.contains(path))
            guard fromPanel else { finish(task, status: 403, type: "text/plain", body: Data()); return }
            let rest = String(path.dropFirst("/agent".count))
            let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
            Task {
                let reply = await link.request(method: method, pathAndQuery: rest + query)
                await MainActor.run {
                    if reply.status < 400 { self.onAgentAnswer?() }
                    self.finish(task, status: reply.status, type: reply.contentType ?? "application/octet-stream", body: reply.body)
                }
            }
            return
        }
        serveFile(task, path: path)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task as AnyObject))
    }

    private func serveFile(_ task: WKURLSchemeTask, path: String) {
        let relative = (path.removingPercentEncoding ?? path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let file = www.appendingPathComponent(relative.isEmpty ? "index.html" : relative).standardizedFileURL
        // nothing outside the bundled panel
        guard file.path.hasPrefix(www.path + "/"), let data = try? Data(contentsOf: file) else {
            finish(task, status: 404, type: "text/plain", body: Data())
            return
        }
        finish(task, status: 200, type: Self.mimeType(file.pathExtension), body: data)
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8" // the panel is ES modules
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    /// Main thread only.
    private func finish(_ task: WKURLSchemeTask, status: Int, type: String, body: Data) {
        guard live.remove(ObjectIdentifier(task as AnyObject)) != nil, let url = task.request.url else { return }
        let headers = ["Content-Type": type, "Cache-Control": "no-store", "Content-Length": String(body.count)]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
    }
}

import Foundation
import WebKit

/// The panel's native bridge (`window.Android` in main.js). The panel calls it synchronously and uses some return
/// values (battery, pcs, transport, version...), but WKWebView only offers asynchronous messages. So a script injected
/// at document start, in the main frame only, defines `window.Android`: its getters read a snapshot the app keeps up to
/// date in `window.__phoneboxHost`, and its actions post to the "phonebox" message handler.
///
/// Methods the iPad cannot do are left out entirely: the panel then treats them as missing (main.js filters BRIDGE by
/// `typeof Android[m] === 'function'`), the same as running without a host. See ios/PROTOCOL.md for the table.
enum Bridge {
    static let handlerName = "phonebox"

    static func bootstrapScript(key: String, languages: [String], snapshot: String) -> String {
        let langs = (try? JSONSerialization.data(withJSONObject: languages)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let keyLiteral = jsString(key)
        return """
        (function () {
          var key = \(keyLiteral);
          window.__phoneboxKey = key;
          window.__phoneboxLanguages = \(langs);
          window.__phoneboxHost = \(snapshot);
          function host() { return window.__phoneboxHost || {}; }
          var speechId = 0; // listen() must answer at once, so the session ids are counted here
          function post(m, args) {
            try { window.webkit.messageHandlers.\(handlerName).postMessage({ key: key, m: m, args: args }); } catch (_) {}
          }
          window.Android = {
            battery: function (k) { return k === key ? JSON.stringify(host().battery || {}) : '{}'; },
            buzz: function () {},
            haptic: function () {},
            is24Hour: function (k) { return k !== key || host().is24Hour !== false; },
            pcs: function (k) { return k === key ? JSON.stringify(host().pcs || []) : '[]'; },
            selectPc: function (k, id) { if (k === key) post('selectPc', [String(id)]); },
            forgetPc: function (k, id) { if (k === key) post('forgetPc', [String(id)]); },
            setBrightness: function (k, v) { if (k === key) post('setBrightness', [Number(v)]); },
            setOrientation: function (k, mode) { if (k === key) post('setOrientation', [String(mode)]); },
            setStandby: function (k, mode, grace) { if (k === key) post('setStandby', [String(mode), Number(grace) || 30]); },
            setLanguage: function (k, tag) { if (k === key) post('setLanguage', [String(tag)]); },
            transport: function (k) { return k === key ? (host().transport || 'none') : ''; },
            sensors: function (k) { return k === key ? '{"light":false,"proximity":false}' : '{}'; },
            version: function (k) { return k === key ? (host().version || '') : ''; },
            canListen: function (k) { return k === key && host().canListen === true; },
            listen: function (k, lang, offline) {
              if (k !== key) return 0;
              speechId += 1;
              post('listen', [speechId, String(lang || ''), offline === true]);
              return speechId;
            },
            stopListening: function (k, id) { if (k === key) post('stopListening', [Number(id) || 0]); },
            cancelListening: function (k, id) { if (k === key) post('cancelListening', [Number(id) || 0]); },
            trackpad: function (k, type, dx, dy, delta) {
              if (k === key) post('trackpad', [String(type), Number(dx) || 0, Number(dy) || 0, Number(delta) || 0]);
            }
          };
        })();
        """
    }

    /// A JavaScript string literal for [s] (JSON-escaped).
    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]), let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// WKUserContentController keeps its handlers strongly; this breaks the cycle with the view controller.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

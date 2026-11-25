import Foundation

/// Keeps one live connection to the agent's /api/stream (server-sent events) and hands every event to [deliver] on the
/// main thread. Port of AgentStream.kt: "open" / "close" pseudo-events tell the panel when to stop or resume its
/// polling fallback; it reconnects after errors, and on Wi-Fi it reopens every minute, as Android does.
@MainActor
final class AgentStream {
    private let link: AgentLink
    private let deliver: (_ event: String, _ data: String) -> Void
    // each start() / stop() advances the generation; a loop from an earlier one delivers nothing more
    private var generation = 0
    private var task: Task<Void, Never>?

    init(link: AgentLink, deliver: @escaping (_ event: String, _ data: String) -> Void) {
        self.link = link
        self.deliver = deliver
    }

    func start() {
        guard task == nil else { return }
        generation += 1
        let gen = generation
        let link = self.link
        let owner = WeakBox(self)
        task = Task.detached {
            await AgentStream.loop(link: link) { event, data in
                await MainActor.run { owner.value?.emit(gen: gen, event: event, data: data) }
            }
        }
    }

    private func emit(gen: Int, event: String, data: String) {
        guard generation == gen, task != nil else { return }
        deliver(event, data)
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
    }

    func restart() {
        stop()
        start()
    }

    private nonisolated static func loop(link: AgentLink, emit: @escaping (String, String) async -> Void) async {
        while !Task.isCancelled {
            var opened = false
            if let bytes = await link.openStream() {
                opened = true
                await emit("open", #"{"route":"wifi"}"#)
                let since = Date()
                var event = "message"
                var data = ""
                var line: [UInt8] = []
                do {
                    reading: for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte != 0x0A { line.append(byte); continue }
                        if line.last == 0x0D { line.removeLast() }
                        let text = String(decoding: line, as: UTF8.self)
                        line.removeAll(keepingCapacity: true)
                        if text.isEmpty {
                            if !data.isEmpty { await emit(event, data) }
                            event = "message"
                            data = ""
                            if Date().timeIntervalSince(since) > 60 { break reading }
                        } else if text.hasPrefix("event:") {
                            event = text.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if text.hasPrefix("data:") {
                            data += String(text.dropFirst(5).drop { $0 == " " })
                        }
                    }
                } catch {
                    // dropped, timed out (8 s of silence) or cancelled
                }
                bytes.task.cancel()
            }
            if opened && !Task.isCancelled { await emit("close", "{}") }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: opened ? 300_000_000 : 2_000_000_000)
        }
    }
}

/// A weak reference that can cross into the stream's background task.
final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// The trackpad widget's moves, as POST /api/trackpad (JSON). One request at a time; while one is in flight, moves and
/// scrolls of the same kind add up, like AgentLink.coalesceHttpTrackpad on Android.
actor TrackpadSender {
    private struct Move { let type: String; var dx: Double; var dy: Double; var delta: Double }

    static let validTypes: Set<String> = ["move", "click", "rightClick", "mousedown", "mouseup", "scroll", "hscroll",
        "swipe3up", "swipe3down", "swipe3left", "swipe3right", "swipe4up", "swipe4down", "swipe4left", "swipe4right",
        "spread", "pinch"]

    private let link: AgentLink
    private var inFlight = false
    private var pending: [Move] = []

    init(link: AgentLink) { self.link = link }

    func send(type: String, dx: Double, dy: Double, delta: Double) {
        guard Self.validTypes.contains(type) else { return }
        let move = Move(type: type, dx: dx.isFinite ? dx : 0, dy: dy.isFinite ? dy : 0, delta: delta.isFinite ? delta : 0)
        if inFlight {
            if var last = pending.last, last.type == type, type == "move" || type == "scroll" {
                last.dx += move.dx; last.dy += move.dy; last.delta += move.delta
                pending[pending.count - 1] = last
            } else {
                pending.append(move)
            }
            return
        }
        inFlight = true
        Task { await drain(move) }
    }

    private func drain(_ first: Move) async {
        var next: Move? = first
        while let move = next {
            let body = try? JSONSerialization.data(withJSONObject: ["type": move.type, "dx": move.dx, "dy": move.dy, "delta": move.delta])
            _ = await link.request(method: "POST", pathAndQuery: "/api/trackpad", body: body, contentType: "application/json")
            next = pending.isEmpty ? nil : pending.removeFirst()
        }
        inFlight = false
    }
}

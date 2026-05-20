import Foundation
import Network

/// Minimal loopback-only HTTP/1.1 server.
/// Accepts POST /hook with a JSON body (the payload Claude Code sends to a hook command).
/// Binds to 127.0.0.1:7842 — never reachable from the LAN.
final class HookServer: @unchecked Sendable {
    static let port: NWEndpoint.Port = NWEndpoint.Port(rawValue: UInt16(HookInstaller.port))!

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentmon.hookserver")
    private let onEvent: @Sendable (HookEvent) -> Void

    var isRunning: Bool { listener?.state == .ready }

    init(onEvent: @escaping @Sendable (HookEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        let params = NWParameters.tcp
        // Loopback-only binding
        if let opts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            opts.version = .v4
        }
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: Self.port)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("[Agentmon] HookServer failed: \(err)")
                }
            }
            listener.start(queue: queue)
        } catch {
            NSLog("[Agentmon] HookServer start failed: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        // Reject non-loopback origins. NWListener binds to all interfaces;
        // we filter at the connection level so LAN peers can't drive our state.
        if !Self.isLoopback(conn.endpoint) {
            NSLog("[Agentmon] Rejecting non-loopback connection from \(conn.endpoint)")
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let addr):
                return addr.rawValue.first == 127  // 127.0.0.0/8
            case .ipv6(let addr):
                return addr == .loopback
            case .name(let s, _):
                return s == "localhost"
            @unknown default:
                return false
            }
        }
        return false
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }

            if let (head, bodyStart) = Self.headerSplit(buffer) {
                let contentLength = Self.parseContentLength(head) ?? 0
                let received = buffer.count - bodyStart
                if received >= contentLength {
                    let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                    self.respond(conn, body: body, head: head)
                    return
                }
            }

            if isComplete || error != nil {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private func respond(_ conn: NWConnection, body: Data, head: String) {
        // Only POST /hook is meaningful
        let isPostHook = head.hasPrefix("POST /hook")
        if isPostHook, let event = HookEvent.parse(body) {
            // onEvent is @Sendable; callee hops to MainActor as needed
            onEvent(event)
        }

        let payload = isPostHook ? "{\"ok\":true}" : "{\"ok\":false}"
        let status = isPostHook ? "200 OK" : "404 Not Found"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// Returns (header string, byte offset where body starts) if the CRLFCRLF boundary is present.
    private static func headerSplit(_ buffer: Data) -> (String, Int)? {
        let needle = Data([0x0d, 0x0a, 0x0d, 0x0a])  // \r\n\r\n
        guard let range = buffer.range(of: needle) else { return nil }
        let headData = buffer.subdata(in: 0..<range.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else { return nil }
        return (head, range.upperBound)
    }

    private static func parseContentLength(_ head: String) -> Int? {
        for line in head.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let v = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                return Int(v)
            }
        }
        return nil
    }
}

/// A hook event received from Claude Code.
/// Different events have different fields; we keep this loose and decode on demand.
struct HookEvent {
    enum Kind: String {
        case sessionStart   = "SessionStart"
        case stop           = "Stop"
        case subagentStop   = "SubagentStop"
        case notification   = "Notification"
        case unknown
    }

    let kind: Kind
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let message: String?
    let raw: [String: Any]

    static func parse(_ data: Data) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let kindStr = (obj["hook_event_name"] as? String) ?? (obj["event"] as? String) ?? ""
        let kind = Kind(rawValue: kindStr) ?? .unknown
        return HookEvent(
            kind: kind,
            sessionId: obj["session_id"] as? String,
            transcriptPath: obj["transcript_path"] as? String,
            cwd: obj["cwd"] as? String,
            message: obj["message"] as? String,
            raw: obj
        )
    }
}

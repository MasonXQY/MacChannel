import Foundation
import MacChannelCore

/// Mirrors App/Resources/RuntimeConfig.json. Mobile production has no endpoint override.
enum MobileRuntimeConfiguration {
    static func diagnosticFrame(_ data: Data) -> String {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "other" }
        if object["type"] as? String == "challenge", let expiry = object["expiresAt"] as? NSNumber {
            let remaining = expiry.doubleValue / 1_000 - Date().timeIntervalSince1970
            if remaining <= 0 { return "challenge_expired" }
            return remaining > 600 ? "challenge_far_future" : "challenge_unexpired"
        }
        if object["type"] as? String == "auth-ok" { return "accepted" }
        if object["type"] as? String == "presence" {
            switch object["availability"] as? String {
            case "internet": return "peer_online"
            case "offline": return "peer_offline"
            default: return "other"
            }
        }
        guard object["type"] as? String == "auth-error",
              let code = object["code"] as? String,
              ["authentication_failed", "capacity_reached"].contains(code)
        else { return "other" }
        return code
    }
    static let webSocketURL = URL(string: "wss://channel.zensys-tech.com/v1/ws")!
    static let httpOrigin = URL(string: "https://channel.zensys-tech.com")!

    /// Each presence attempt owns the session that core invalidates on close.
    /// TURN uses a separate foreground HTTP session in the stage-B owner.
    static func makePresenceSocket(
        build: (URLSession) throws -> any PresenceWebSocket = {
            let socket = try URLSessionPresenceWebSocket(origin: webSocketURL, session: $0)
            #if DEBUG
            return MobileDiagnosticSocket(socket: socket)
            #else
            return socket
            #endif
        }
    ) rethrows -> any PresenceWebSocket {
        try build(URLSession(configuration: .ephemeral))
    }
}

#if DEBUG
private struct MobileDiagnosticSocket: PresenceWebSocket {
    let socket: any PresenceWebSocket
    func send(_ data: Data) async throws { try await socket.send(data) }
    func ping() async throws { try await socket.ping() }
    func close() async { await socket.close() }
    func receive() async throws -> Data {
        let data = try await socket.receive()
        let category = MobileRuntimeConfiguration.diagnosticFrame(data)
        if category != "other" { print("DropMeshPresence response=\(category)") }
        return data
    }
}
#endif

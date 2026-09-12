import Foundation
import MacChannelCore

/// Mirrors App/Resources/RuntimeConfig.json. Mobile production has no endpoint override.
enum MobileRuntimeConfiguration {
    static let webSocketURL = URL(string: "wss://channel.zensys-tech.com/v1/ws")!
    static let httpOrigin = URL(string: "https://channel.zensys-tech.com")!

    /// Each presence attempt owns the session that core invalidates on close.
    /// TURN uses a separate foreground HTTP session in the stage-B owner.
    static func makePresenceSocket(
        build: (URLSession) throws -> any PresenceWebSocket = {
            try URLSessionPresenceWebSocket(origin: webSocketURL, session: $0)
        }
    ) rethrows -> any PresenceWebSocket {
        try build(URLSession(configuration: .ephemeral))
    }
}

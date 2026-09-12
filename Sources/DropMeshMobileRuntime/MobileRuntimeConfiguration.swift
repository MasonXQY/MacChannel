import Foundation

/// Mirrors App/Resources/RuntimeConfig.json. Mobile production has no endpoint override.
enum MobileRuntimeConfiguration {
    static let webSocketURL = URL(string: "wss://channel.zensys-tech.com/v1/ws")!
    static let httpOrigin = URL(string: "https://channel.zensys-tech.com")!
}

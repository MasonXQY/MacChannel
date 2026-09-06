import AppKit
import Foundation
import MacChannelAppKit
import MacChannelCore

@MainActor
package final class AppStoreDistribution: ApplicationDistribution {
    private static let bundleIdentifier = "com.zensystech.dropmesh"
    private static let identityService = "com.zensystech.dropmesh.identity"
    private static let keychainAccessGroup = "XKAZ67HN45.com.zensystech.dropmesh"
    private static let conflictingDirectBundleIdentifier = "com.mason.macchannel"

    package let channel: DistributionChannel = .appStore
    package let updates: any SoftwareUpdateControlling
    package let runtimeNamespace: RuntimeNamespace
    package let conflictingBundleIdentifiers: Set<String>

    package init(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        conflictingBundleIdentifiers = [Self.conflictingDirectBundleIdentifier]
        runtimeNamespace = RuntimeNamespace(
            applicationSupportComponent: "DropMesh",
            identityPolicy: KeychainPolicy(
                service: Self.identityService,
                accessibility: .afterFirstUnlockThisDeviceOnly,
                synchronizable: false
            ),
            keychainAccessGroup: Self.keychainAccessGroup,
            defaultReceiveFolderName: "DropMesh"
        )
        updates = AppStoreUpdateController(
            appStoreURL: Self.appStoreURL(from: info["DropMeshAppStoreID"]),
            installedVersion: InstalledAppVersion(info: info),
            openURL: openURL
        )
    }

    private static func appStoreURL(from rawValue: Any?) -> URL? {
        let identifier: UInt64?
        switch rawValue {
        case let value as String:
            guard !value.isEmpty,
                  value.allSatisfy({ $0 >= "0" && $0 <= "9" })
            else { return nil }
            identifier = UInt64(value)
        case let value as Int:
            identifier = value > 0 ? UInt64(value) : nil
        case let value as UInt64:
            identifier = value
        default:
            identifier = nil
        }
        guard let identifier, identifier > 0 else { return nil }
        return URL(string: "macappstore://itunes.apple.com/app/id\(identifier)")
    }
}

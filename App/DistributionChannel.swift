import Foundation
import MacChannelCore

package enum DistributionChannel: String, Sendable {
    case direct
    case appStore
}

package struct RuntimeNamespace: Equatable, Sendable {
    package let applicationSupportComponent: String
    package let identityPolicy: KeychainPolicy
    package let keychainAccessGroup: String?
    package let defaultReceiveFolderName: String

    package init(
        applicationSupportComponent: String,
        identityPolicy: KeychainPolicy,
        keychainAccessGroup: String?,
        defaultReceiveFolderName: String
    ) {
        self.applicationSupportComponent = applicationSupportComponent
        self.identityPolicy = identityPolicy
        self.keychainAccessGroup = keychainAccessGroup
        self.defaultReceiveFolderName = defaultReceiveFolderName
    }

    package static let direct = RuntimeNamespace(
        applicationSupportComponent: "MacChannel",
        identityPolicy: KeychainStore.identityPolicy,
        keychainAccessGroup: nil,
        defaultReceiveFolderName: "Mac 通道"
    )
}

@MainActor
package protocol ApplicationDistribution: AnyObject {
    var channel: DistributionChannel { get }
    var updates: any SoftwareUpdateControlling { get }
    var runtimeNamespace: RuntimeNamespace { get }
    var conflictingBundleIdentifiers: Set<String> { get }
}

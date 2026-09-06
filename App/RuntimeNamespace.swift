import MacChannelCore

package struct RuntimeNamespace: Equatable, Sendable {
    package let applicationSupportComponent: String
    package let identityPolicy: KeychainPolicy
    package let defaultReceiveFolderName: String
    package let directoryAuthorizationMode: DirectoryAuthorizationMode
    package var keychainAccessGroup: String? { identityPolicy.accessGroup }

    package init(applicationSupportComponent: String, identityPolicy: KeychainPolicy,
                 defaultReceiveFolderName: String,
                 directoryAuthorizationMode: DirectoryAuthorizationMode = .directPath) {
        self.applicationSupportComponent = applicationSupportComponent
        self.identityPolicy = identityPolicy
        self.defaultReceiveFolderName = defaultReceiveFolderName
        self.directoryAuthorizationMode = directoryAuthorizationMode
    }

    package static let direct = RuntimeNamespace(
        applicationSupportComponent: "MacChannel",
        identityPolicy: KeychainStore.identityPolicy,
        defaultReceiveFolderName: "Mac 通道"
    )
}

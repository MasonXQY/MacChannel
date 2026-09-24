import Foundation

public enum AccountFirstDeviceEnrollmentError: Error, Equatable, Sendable {
    case unavailable, approvalRequired, invalidAttempt, secureStorage
}

public struct AccountFirstDeviceEnrollment: Sendable {
    let identity: DeviceIdentity
    let intentStorage: any AccountGroupBootstrapIntentStorage

    public init(identity: DeviceIdentity,
                intentStorage: any AccountGroupBootstrapIntentStorage = KeychainAccountGroupBootstrapIntentStorage()) {
        self.identity = identity
        self.intentStorage = intentStorage
    }
}

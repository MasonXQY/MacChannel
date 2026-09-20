import Foundation

public struct AccountGroupBootstrapIntent: Equatable, Sendable {
    public let binding: AccountSessionBinding
    public let event: AccountGroupEvent

    public init(binding: AccountSessionBinding, event: AccountGroupEvent) throws {
        do {
            try event.validate()
            guard event.action == "bootstrap", event.generation == 1,
                  event.actorDeviceID == binding.deviceID.uuidString.lowercased(),
                  event.subjectDeviceID == binding.deviceID.uuidString.lowercased() else {
                throw AccountFirstDeviceEnrollmentError.secureStorage
            }
        } catch { throw AccountFirstDeviceEnrollmentError.secureStorage }
        self.binding = binding
        self.event = event
    }
}

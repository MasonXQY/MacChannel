public struct DeviceSummary: Hashable, Sendable {
    public let id: DeviceID
    public let displayName: String
    public let availability: DeviceAvailability

    public init(id: DeviceID, displayName: String, availability: DeviceAvailability) {
        self.id = id
        self.displayName = displayName
        self.availability = availability
    }
}

public enum DeviceAvailability: String, Codable, Sendable {
    case offline
    case lan
    case internet
}

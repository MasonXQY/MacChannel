import Foundation
import MacChannelCore

extension DeviceSummary {
    var userFacingDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let suffix = id.rawValue.uuidString.prefix(4).uppercased()
            return "已配对 Mac \(suffix)"
        }
        return trimmed
    }

    func replacingDisplayName(_ displayName: String) -> DeviceSummary {
        DeviceSummary(id: id, displayName: displayName, availability: availability)
    }
}

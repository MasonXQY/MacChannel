import Foundation
import MacChannelCore

package enum DistributionChannel: String, Sendable {
    case direct
    case appStore
}

@MainActor
package protocol ApplicationDistribution: AnyObject {
    var channel: DistributionChannel { get }
    var updates: any SoftwareUpdateControlling { get }
    var runtimeNamespace: RuntimeNamespace { get }
    var conflictingBundleIdentifiers: Set<String> { get }
}

import MacChannelAppKit

@MainActor
package final class DirectDistribution: ApplicationDistribution {
    package let channel: DistributionChannel = .direct
    package let updates: any SoftwareUpdateControlling
    package let runtimeNamespace = RuntimeNamespace.direct
    package let conflictingBundleIdentifiers: Set<String> = []

    package init() {
        updates = SparkleUpdateController()
    }
}

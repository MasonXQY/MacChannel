import DropMeshAppStoreDistribution
import MacChannelAppKit

@main
struct DropMeshAppStoreApp {
    @MainActor
    static func main() {
        MacChannelApplication.run(distribution: AppStoreDistribution())
    }
}

import MacChannelAppKit
import MacChannelDirectDistribution

@main
struct MacChannelDirectApp {
    @MainActor
    static func main() {
        MacChannelApplication.run(distribution: DirectDistribution())
    }
}

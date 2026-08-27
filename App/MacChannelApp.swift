import AppKit
import Foundation

@MainActor
public enum MacChannelApplication {
    public static func run() {
        let application = NSApplication.shared
        let delegate = MacChannelApplicationDelegate(container: .localShell())
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class MacChannelApplicationDelegate: NSObject, NSApplicationDelegate {
    private let container: AppContainer
    private var statusItemController: StatusItemController?

    init(container: AppContainer) {
        self.container = container
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(
            deviceDirectory: container.deviceDirectory,
            transferCoordinator: container.transferCoordinator
        )
        completeLaunchSmokeTestIfRequested()
    }

    private func completeLaunchSmokeTestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--smoke-test"),
              arguments.indices.contains(flag + 1),
              NSApplication.shared.activationPolicy() == .accessory,
              statusItemController != nil
        else { return }

        let marker = URL(fileURLWithPath: arguments[flag + 1])
        try? Data("ready accessory\n".utf8).write(to: marker, options: .atomic)
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}

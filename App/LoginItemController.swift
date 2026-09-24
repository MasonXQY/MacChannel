import ServiceManagement

@MainActor
protocol LoginItemRegistering: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

extension LoginItemRegistering {
    var isEnabled: Bool { false }
}

@MainActor
final class LoginItemController: LoginItemRegistering {
    static let shared = LoginItemController()

    private init() {}

    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}

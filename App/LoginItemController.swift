import ServiceManagement

@MainActor
protocol LoginItemRegistering: AnyObject {
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
final class LoginItemController: LoginItemRegistering {
    static let shared = LoginItemController()

    private init() {}

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

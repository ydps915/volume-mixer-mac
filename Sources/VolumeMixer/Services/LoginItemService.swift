import Foundation
import ServiceManagement

enum LoginItemService {
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `SMAppService` refuses to register an app that is not in a stable,
    /// properly signed location, and the raw error says very little.
    static func failureMessage(for error: Error) -> String {
        let base = "Não foi possível atualizar o item de login: \(error.localizedDescription)"
        guard SMAppService.mainApp.status == .notFound || isInTemporaryLocation else {
            return base
        }
        return base + " Mova o Volume Mixer para a pasta Aplicativos e tente novamente."
    }

    private static var isInTemporaryLocation: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return !path.hasPrefix("/Applications/")
            && !path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}

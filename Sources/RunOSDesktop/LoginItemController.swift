import Combine
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published var isEnabled: Bool
    @Published var errorMessage: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = nil
        } catch {
            isEnabled = SMAppService.mainApp.status == .enabled
            errorMessage = error.localizedDescription
        }
    }
}

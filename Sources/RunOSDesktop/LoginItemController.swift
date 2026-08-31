import Combine
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published var isEnabled: Bool
    @Published var errorMessage: String?

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /*
     Re-read the real setting, because the person can change it somewhere else.

     `isEnabled` was read once at init and then trusted for the life of the process, and this is a
     menu bar app that stays resident for days. Somebody who removes RunOS Desktop under System
     Settings > General > Login Items goes on seeing "Launch at Login" ticked for the rest of that
     lifetime, so the menu asserts a behaviour the app no longer has. The reverse is the same:
     adding it there leaves the toggle unticked, so somebody who wants it leaves it alone and it
     never happens. Recovery took a double toggle or a relaunch.

     Called when the menu opens, which is the only moment the value is looked at, and the status is
     a cheap local read.
    */
    func refresh() {
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

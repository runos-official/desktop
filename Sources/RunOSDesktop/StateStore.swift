import Combine
import Foundation

@MainActor
final class StateStore: ObservableObject {
    @Published var cliStatus: CLIStatus?
    @Published var vpnStatus: VPNStatus?
    @Published var errorMessage: String?
    @Published var operationMessage: String?
    @Published var canCancelOperation = false
    @Published var cancelOperationLabel: String?
    @Published var cancellingOperationMessage: String?
    @Published var cliAvailable = true
    @Published var cliOutdated = false
    @Published var cliDevelopment = false
    @Published var cliVersion: String?
    /*
     The VPN needs a sign-in that the app cannot perform on the person's behalf.

     This is the ONLY thing an account difference is allowed to surface. The app follows the
     account you are signed in to by itself; when Conductor wants a fresh sign-in it cannot, and
     that is a thing to do rather than a state to explain.
    */
    @Published var vpnSignInRequired = false

    var activeAccountId: String? { cliStatus?.accountId }
    var isBusy: Bool { operationMessage != nil }
    var updateActionTitle: String {
        operationMessage == "Updating RunOS…" ? "Updating RunOS…" : "Update RunOS"
    }

    var menuBarState: MenuBarState {
        if isBusy || errorMessage != nil || cliOutdated || vpnSignInRequired || vpnStatus?.session.loginRequired == true {
            return .attention
        }
        // `running` is only the tunnel interface. The connected icon is a claim that the VPN is
        // carrying something, so it needs a cluster that is connected AND reachable. A tunnel that
        // is up while every connected cluster is dead is the defect this guards: it looked
        // connected and reached nothing.
        if vpnStatus?.hasWorkingConnection == true {
            return .connected
        }
        if vpnStatus?.running == true {
            return .attention
        }
        return .off
    }
}

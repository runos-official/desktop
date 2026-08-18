import Combine
import Foundation

@MainActor
final class StateStore: ObservableObject {
    @Published var cliStatus: CLIStatus?
    @Published var accounts: [AccountEntry] = []
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

    var activeAccountId: String? { cliStatus?.accountId }
    var isBusy: Bool { operationMessage != nil }
    var updateActionTitle: String {
        operationMessage == "Updating RunOS…" ? "Updating RunOS…" : "Update RunOS"
    }

    var menuBarState: MenuBarState {
        if isBusy || errorMessage != nil || cliOutdated || cliStatus?.vpnAccountMismatch == true || vpnStatus?.session.loginRequired == true {
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

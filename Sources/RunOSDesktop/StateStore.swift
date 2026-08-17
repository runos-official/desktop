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

    var menuBarState: MenuBarState {
        if isBusy || errorMessage != nil || cliOutdated || cliStatus?.vpnAccountMismatch == true || vpnStatus?.session.loginRequired == true {
            return .attention
        }
        if vpnStatus?.running == true {
            return .connected
        }
        return .off
    }
}

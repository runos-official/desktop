import Combine
import Foundation

@MainActor
final class StateStore: ObservableObject {
    @Published var cliStatus: CLIStatus?
    @Published var vpnStatus: VPNStatus?
    @Published var traffic = TrafficSampler()
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

    /*
     Whether the person must sign in again before the VPN carries anything.

     TWO causes, one prompt. `vpnSignInRequired` is the account-follow path: the app tried to switch
     accounts by itself and Conductor wanted a fresh sign-in. `session.loginRequired` is the plain
     expiry, and it was the one nobody was told about: the menu bar tinted, the menu said nothing,
     the cluster still showed connected, and every packet was dropped (reported 2026-08-25). A
     person cannot act on a tinted icon.
    */
    var signInRequired: Bool {
        vpnSignInRequired || vpnStatus?.session.loginRequired == true || cliSessionExpired
    }

    /// Conductor refused the CLI's sign-in because it aged out. See CLIStatus.sessionExpired.
    var cliSessionExpired: Bool { cliStatus?.sessionExpired == true }

    /*
     Whether the session ends soon enough to be worth interrupting for.

     In the VPN submenu the expiry is reference, and a person looks it up. Inside the last hour it
     is something to act on, so it moves to the top-level status where it cannot be missed. One
     hour because a sign-in takes a browser round trip, and being told with five minutes left is
     being told too late.
    */
    func sessionEndingSoon(now: Date) -> Bool {
        guard let session = vpnStatus?.session, session.present, !session.loginRequired,
              let expiresAt = session.expiresAt else { return false }
        let remaining = expiresAt.timeIntervalSince(now)
        return remaining > 0 && remaining <= 3600
    }

    /*
     Which of three things the VPN submenu is looking at, decided by the SESSION first.

     Deciding on `vpn.running` was the defect: that is the tunnel INTERFACE, it stays up through a
     session expiry, and so the submenu ticked a cluster as connected and offered to sign out of a
     session that had already ended. Greying it stopped the clicks and changed nothing about the
     claim; a disabled control is still a sentence, and that sentence was wrong.

     `signedOut` therefore wins over a running tunnel, and covers the account-switch cause too.
     Unknown state at first launch is NOT signedOut: nothing has been read yet, and saying "signed
     out" then would be inventing a fact.
    */
    var vpnMenuMode: VPNMenuMode {
        if signInRequired { return .signedOut }
        return vpnStatus?.running == true ? .connected : .disconnected
    }

    /*
     Whether anything in the VPN submenu can still do what its label says.

     The submenu was gated on `vpn.running`, which is only the tunnel INTERFACE. An expired session
     leaves that interface up, so the menu drew every cluster as a ticked toggle and offered to
     sign out of a session that had already ended (reported 2026-08-25). The tick is the worse
     half: it is the app asserting a cluster is connected and carrying traffic while nothing routes,
     which is the same defect the dead-connection rule exists to prevent, arriving by another door.

     Nobody is trapped by this. The only useful action in that state is a sign-in, and the Sign In
     button sits directly above the submenu; signing in mints a new session and rebuilds the tunnel,
     so the stale one does not need tearing down by hand first.
    */
    var vpnControlsUsable: Bool { !signInRequired }

    var activeAccountId: String? { cliStatus?.accountId }
    var isBusy: Bool { operationMessage != nil }
    var updateActionTitle: String {
        operationMessage == "Updating RunOS…" ? "Updating RunOS…" : "Update RunOS"
    }

    var menuBarState: MenuBarState {
        if isBusy || errorMessage != nil || cliOutdated || signInRequired {
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

/// What the VPN submenu is showing. See `StateStore.vpnMenuMode` for why the session decides it.
enum VPNMenuMode: Equatable {
    /// A sign-in is owed. No clusters, no actions, and above all no tick over a dead path.
    case signedOut
    /// A live session on an up tunnel: the clusters, when the session ends, and Sign Out.
    case connected
    /// A live session with the tunnel down, or nothing read yet: the one useful action is Connect.
    case disconnected
}

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
     Whether an update is waiting for either component, from `runos update --check --json`.

     Kept separate from every VPN state on purpose: an update waiting is not a VPN problem, and a
     disconnected VPN must not hide that one is waiting.
    */
    @Published var updateAvailable = false

    /*
     Whether the CLI answered the update question at all. nil until the first check, and false
     against a CLI too old to carry the verdict.

     Kept separate from `updateAvailable` because the two consumers want opposite defaults: see
     `UpdateCheck.verdictKnown`.
    */
    @Published var updateVerdictKnown: Bool?

    /*
     The VPN system service is not installed, so nothing can carry a tunnel.

     A SEPARATE STATE FROM signInRequired, because the two remedies share nothing. `runos desktop
     install` writes the app and not the root LaunchDaemon the tunnel needs, so this is the ordinary
     condition of a fresh machine rather than an error. Reported as "sign in required" until
     2026-08-25, which sent people to a browser to fix a missing daemon.
    */
    @Published var vpnServiceMissing = false

    /*
     WHETHER THERE IS AN IDENTITY, and it comes from `runos status`. Only from `runos status`.

     This is the whole of FPL26 D1. The app used to have no concept of a CLI sign-in: Sign In ran
     `vpn up`, Sign Out ran `vpn down`, and so "signed in" here meant "has a VPN session". A machine
     could report `"authenticated": false` and `"vpnRunning": true` from one command, and this app
     would draw the second and never the first.

     Nil is not false. Nothing has been read yet at first launch, and saying "signed out" then would
     be inventing a fact.
    */
    var signedIn: Bool { cliStatus?.authenticated == true }

    /*
     Whether the person must sign in again, which is a thing to DO and has a button.

     Guarded on the kind, because `authenticated: false` also covers a refresh that could not reach
     Google at all (FCR160). A ten second network blip must not offer a browser sign-in for a session
     that is perfectly valid, and must not tint the menu bar for it either.
    */
    var signInRequired: Bool {
        guard let status = cliStatus else { return false }
        return !status.authenticated && status.authErrorKind != "network"
    }

    /// Conductor refused the CLI's sign-in because it aged out. See CLIStatus.sessionExpired.
    var cliSessionExpired: Bool { cliStatus?.sessionExpired == true }

    /*
     Whether the tunnel is up AND the session behind it is live.

     `running` alone is the tunnel INTERFACE, which stays up through a session expiry. Reading it as
     "connected" is what drew a ticked, connected-looking cluster over a path that dropped every
     packet (reported 2026-08-25).
    */
    var vpnConnected: Bool {
        vpnStatus?.running == true && vpnStatus?.session.loginRequired != true
    }

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
        // No identity, nothing to connect with. The Sign In button above the submenu is the remedy,
        // and it now signs the person in rather than trying to open a tunnel.
        if signInRequired { return .signedOut }
        return vpnConnected ? .connected : .disconnected
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
    var vpnControlsUsable: Bool { signedIn && !vpnServiceMissing }

    /*
     Whether Update RunOS can do anything if clicked.

     DISABLED, NOT HIDDEN, which is the rule this menu already follows for the VPN submenu: someone
     opening the menu looking for it should find it where it always is and see there is nothing to
     do, rather than watch it vanish and wonder what the app has lost.

     False while an update is already running, so it cannot be started twice.
    */
    /*
     Whether Update RunOS can do anything if clicked. THREE states, not two.

       nil    nothing has been asked yet. DISABLED: every launch starts here and the answer lands
              about a second later, so treating it as "there might be an update" would flash a
              clickable button with no badge beside it on every single launch.
       false  we asked and got no verdict, because the CLI is too old to carry one or the check
              could not run. ENABLED, because disabling it would leave no way to update at all.
       true   we have a verdict, so follow it.
    */
    var updateActionEnabled: Bool {
        guard operationMessage == nil else { return false }
        switch updateVerdictKnown {
        case .none: return false
        case .some(false): return true
        case .some(true): return updateAvailable
        }
    }

    var activeAccountId: String? { cliStatus?.accountId }
    var isBusy: Bool { operationMessage != nil }
    var updateActionTitle: String {
        operationMessage == "Updating RunOS…" ? "Updating RunOS…" : "Update RunOS"
    }

    var menuBarState: MenuBarState {
        if isBusy || errorMessage != nil || cliOutdated || signInRequired {
            return .attention
        }
        /*
         `running` is only the tunnel interface. The connected icon is a claim that the VPN is
         carrying something, so it needs a LIVE SESSION and a cluster that is connected AND
         reachable. A tunnel that is up while every connected cluster is dead is the defect this
         guards: it looked connected and reached nothing.

         `vpnConnected` is load-bearing here and was easy to lose. While `signInRequired` still
         meant "the VPN session ended", the check above happened to cover an expired session too.
         Separating the identity from the tunnel (FPL26 D1) took that cover away, and an expired
         session with a still-ticked cluster went straight back to showing the connected icon.
        */
        if vpnConnected, vpnStatus?.hasWorkingConnection == true {
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

/*
 The CLI commands this app runs, and the line it draws between two things that used to be one.

 SIGNING IN AND CONNECTING ARE DIFFERENT ACTIONS (FPL26 D1).

 Sign In used to be `vpn up` and Sign Out used to be `vpn down`. Neither touched the CLI's
 credentials, so inside this app "signed in" literally meant "has a VPN session". Three things
 followed from that, all reported:

 - A signed-out CLI could never be signed in from here. `vpn up` resolves a credential before it
   does anything else, so the button ran a command that exited immediately (reported 2026-08-28).
 - Sign Out left the machine signed in. `runos status` would report `"authenticated": false` and
   `"vpnRunning": true` from the same invocation.
 - An account switch went through the connect path, which is account-scoped end to end, and failed
   halfway (reported 2026-08-26).

 Identity is now `login` / `logout`. The tunnel is `vpn up` / `vpn down`. One identity, and a
 tunnel that uses it.
*/
enum DesktopCommands {
    /*
     Establish an identity. THE ONLY command in this app that creates one.

     `--no-browser` so the sign-in window opens it, on a click. Otherwise the CLI opens a browser two
     seconds in and the device code is behind it before anyone has read it, which turns the
     comparison the code exists for into a race against a window appearing.
    */
    static func signIn() -> [String] {
        ["login", "--json", "--no-browser"]
    }

    /*
     End the identity, and with it the tunnel (D3: the tunnel never outlives the identity that
     opened it). `runos logout` drops the tunnel itself, so this is one command and not two.
    */
    static func signOut() -> [String] {
        ["logout"]
    }

    /*
     Bring the tunnel up, or take it down. NEVER a sign-in.

     `up` can still need a browser round trip, because conductor mints a VPN session only from a
     sign-in in the last five minutes. That is the "2FA on the VPN" gate and it is deliberate. It is
     a CONFIRMATION, not a sign-in: it cannot change the active account, and the app never calls it
     one. `--no-browser` for the same reason as `signIn`.
    */
    static func setVPN(enabled: Bool) -> [String] {
        enabled ? ["vpn", "up", "--json", "--no-browser"] : ["vpn", "down", "--json"]
    }

    /*
     The unattended connect run at startup.

     `--non-interactive` is the whole difference from `setVPN(enabled: true)`: a browser window
     appearing on its own at login is worse than staying disconnected, so this fails cleanly when
     a fresh sign-in is genuinely needed and leaves the person to do it when they choose.
    */
    static func connectVPNAtStartup() -> [String] {
        ["vpn", "up", "--non-interactive", "--json"]
    }

    static func setCluster(_ cid: String, connected: Bool) -> [String] {
        ["vpn", connected ? "disconnect" : "connect", cid, "--json"]
    }

    /*
     A cluster toggle NEVER ends the session. Disconnecting the last cluster used to run
     `vpn down`, which ends the 24-hour session, so a single-cluster account paid a fresh
     browser sign-in on every reconnect. The daemon keeps the tunnel and the session alive
     with zero clusters connected; Disconnect (`vpn down`) is the one explicit way to end it.
    */
    static func toggleCluster(_ cid: String, isConnected: Bool) -> [String] {
        setCluster(cid, connected: isConnected)
    }
}

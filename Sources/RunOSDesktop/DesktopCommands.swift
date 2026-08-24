enum DesktopCommands {
    static func setVPN(enabled: Bool) -> [String] {
        ["vpn", enabled ? "up" : "down", "--json"]
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
     with zero clusters connected; Sign Out (`vpn down`) is the one explicit way to end it.
    */
    static func toggleCluster(_ cid: String, isConnected: Bool) -> [String] {
        setCluster(cid, connected: isConnected)
    }
}

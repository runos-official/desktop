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

    static func toggleCluster(_ cid: String, isConnected: Bool, connectedClusterCount: Int) -> [String] {
        if isConnected, connectedClusterCount == 1 {
            return setVPN(enabled: false)
        }
        return setCluster(cid, connected: isConnected)
    }
}

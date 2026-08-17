enum DesktopCommands {
    static func switchAccount(_ accountId: String) -> [String] {
        ["account", "switch", accountId, "--json"]
    }

    static func setVPN(enabled: Bool) -> [String] {
        ["vpn", enabled ? "up" : "down", "--json"]
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

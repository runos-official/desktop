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
}

import Foundation

struct CLIStatus: Decodable, Equatable, Sendable {
    let schemaVersion: Int?
    let authenticated: Bool
    let accountId: String?
    let companyName: String?
    let vpnAccountId: String?
    let vpnAccountMismatch: Bool?
    let vpnRunning: Bool?
    let authError: String?
}

struct VPNStatus: Decodable, Equatable, Sendable {
    let schemaVersion: Int?
    let running: Bool
    let accountId: String?
    let session: VPNSession
    let clusters: [VPNCluster]
    let lastPollError: String?

    /*
     Every cluster worth a row in the menu.

     A DEAD connection (in the connected set, no reachable server) stays in this list on purpose,
     even though it is not connectable: the menu is the only place a person can switch it off, so
     hiding it would trap them in that state. What must not happen is presenting it as working;
     `isDeadConnection` and `hasWorkingConnection` are what keep the two apart.
     */
    var connectableClusters: [VPNCluster] {
        clusters.filter { $0.reachable || $0.connected }
    }

    /// Clusters recorded as connected whose server cannot serve them: connected in name only.
    var deadConnections: [VPNCluster] {
        clusters.filter(\.isDeadConnection)
    }

    /*
     Whether the VPN is actually carrying anything.

     The tunnel interface being up (`running`) says nothing about the other end. Only a cluster
     that is BOTH in the connected set and reachable is a connection, and only that earns the
     connected icon.
     */
    var hasWorkingConnection: Bool {
        clusters.contains { $0.connected && $0.reachable }
    }
}

struct VPNSession: Decodable, Equatable, Sendable {
    let present: Bool
    let expiresAt: Date?
    let loginRequired: Bool
}

struct VPNCluster: Decodable, Equatable, Identifiable, Sendable {
    let cid: String
    let name: String
    let connected: Bool
    let reachable: Bool
    let reason: String?
    let peerUp: Bool
    let peeredWith: [String]

    var id: String { cid }

    /*
     Connected in the record, and reaching nothing.

     This is a state a person cannot fix by waiting: the device is in the cluster's connected set
     while its VPN server is missing, so nothing routes and nothing will. The CLI now refuses to
     create it; devices that entered it before that guard existed still have to be shown, and shown
     as broken rather than as a tick.
     */
    var isDeadConnection: Bool { connected && !reachable }
}

struct UpdateResult: Decodable, Sendable {
    struct Component: Decodable, Sendable {
        let updated: Bool
        let version: String?
        let message: String?
    }

    let schemaVersion: Int
    let cli: Component
    let desktop: Component?
}

enum MenuBarState: Equatable, Sendable {
    case connected
    case attention
    case off
}

extension JSONDecoder {
    static var runOS: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

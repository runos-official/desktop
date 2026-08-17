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

struct AccountListResult: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let accounts: [AccountEntry]
}

struct AccountEntry: Decodable, Equatable, Identifiable, Sendable {
    let accountId: String
    let active: Bool
    let addedAt: String
    let lastUsedAt: String
    let vpnIdentityPresent: Bool
    let vpnSessionPresent: Bool
    let vpnSessionExpiresAt: Date?

    var id: String { accountId }
}

struct VPNStatus: Decodable, Equatable, Sendable {
    let schemaVersion: Int?
    let running: Bool
    let accountId: String?
    let session: VPNSession
    let clusters: [VPNCluster]
    let lastPollError: String?

    var connectableClusters: [VPNCluster] {
        clusters.filter { $0.reachable || $0.connected }
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

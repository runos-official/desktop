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
    /*
     Conductor refused the sign-in because it aged out. A FLAG, not a sentence to match on.

     `authError` in this case carries conductor's terminal wording ("Your session is 28 hours old
     ... Run `runos login` to sign in again"), which is right for a terminal and wrong for a menu
     with a Sign In button two lines above it. Older CLIs omit the field, which reads as false: an
     unknown state stays whatever it was rather than claiming a signed-out one.
    */
    let sessionExpired: Bool?
    /*
     WHY A FAILED REFRESH HAS A KIND (FCR160).

     `authenticated: false` used to mean two unrelated things: the sign-in was refused, or the CLI
     could not reach Google's token endpoint at all. A ten second timeout on a train therefore read
     as being signed out, and put `request failed: Post "https://securetoken.googleapis.com/...":
     context deadline exceeded` in the menu bar.

     "network" means the check did not complete and the sign-in is untouched. "rejected" means it is
     genuinely gone. Absent, on an older CLI, reads as neither, which keeps the previous behaviour
     for a build that cannot tell us.
    */
    let authErrorKind: String?
}

struct VPNStatus: Decodable, Equatable, Sendable {
    let schemaVersion: Int?
    let running: Bool
    let accountId: String?
    let session: VPNSession
    let clusters: [VPNCluster]
    let lastPollError: String?
    // Network detail for the About panel. All optional: an older CLI simply omits them.
    let interface: String?
    let address: String?
    let dns: VPNDns?

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

struct VPNDns: Decodable, Equatable, Sendable {
    let available: Bool
    let mode: String?
    let error: String?
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
    // Stats for the About panel. All optional: an older CLI simply omits them.
    let endpoint: String?
    let resolver: String?
    let zones: [String]?
    let rxBytes: Int64?
    let txBytes: Int64?
    let lastHandshake: Date?

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

/*
 Formatting for the About panel's network stats. Pure, so the byte and handshake rendering is
 testable without a panel.
 */
enum StatsFormatting {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: value)
    }

    /*
     WireGuard reports "never handshaken" as the zero time, which the CLI passes through as
     0001-01-01. Anything before 2000 is that sentinel, not a real handshake.
     */
    static func handshake(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date.timeIntervalSince1970 > 946_684_800 else { return "never" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

/*
 Traffic history for the About panel's last-hour bar chart.

 Fed from the vpn status the app already polls (no extra process, no extra load): each poll
 records the cumulative rx+tx total across every cluster, and the delta since the previous poll
 lands in a wall-clock-aligned five-minute bucket. Twelve buckets make the hour. In memory only,
 by design: the history lives as long as the app does.
 */
struct TrafficBucket: Equatable, Sendable {
    let start: Date
    var bytes: Int64
}

struct TrafficSampler: Equatable, Sendable {
    static let bucketSeconds: TimeInterval = 300
    static let capacity = 12

    private(set) var buckets: [TrafficBucket] = []
    private var lastTotal: Int64?

    mutating func record(total: Int64, at now: Date = Date()) {
        // A WireGuard counter resets when a peer is re-added (reconnect, server move). A total
        // below the last one is that reset, and the bytes since it are the new total itself.
        let delta: Int64
        if let last = lastTotal {
            delta = total >= last ? total - last : total
        } else {
            delta = 0
        }
        lastTotal = total
        guard delta >= 0 else { return }
        let start = Date(
            timeIntervalSince1970: (now.timeIntervalSince1970 / Self.bucketSeconds).rounded(.down)
                * Self.bucketSeconds
        )
        if let index = buckets.indices.last, buckets[index].start == start {
            buckets[index].bytes += delta
        } else {
            buckets.append(TrafficBucket(start: start, bytes: delta))
            if buckets.count > Self.capacity {
                buckets.removeFirst(buckets.count - Self.capacity)
            }
        }
    }

    /*
     The chart's twelve slots, oldest first, aligned to the wall clock so a gap (the Mac slept,
     the app was quit) renders as empty bars rather than compressing time.
     */
    func hourSlots(now: Date = Date()) -> [Int64] {
        let currentStart = (now.timeIntervalSince1970 / Self.bucketSeconds).rounded(.down) * Self.bucketSeconds
        return (0..<Self.capacity).map { offset in
            let slotStart = Date(
                timeIntervalSince1970: currentStart - Double(Self.capacity - 1 - offset) * Self.bucketSeconds
            )
            return buckets.first(where: { $0.start == slotStart })?.bytes ?? 0
        }
    }

    var lastHourTotal: Int64 {
        hourSlots().reduce(0, +)
    }
}

extension VPNStatus {
    /// Cumulative rx+tx across every cluster, the number the traffic sampler tracks.
    var totalTrafficBytes: Int64 {
        clusters.reduce(0) { $0 + ($1.rxBytes ?? 0) + ($1.txBytes ?? 0) }
    }
}

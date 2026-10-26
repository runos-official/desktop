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

extension CLIStatus {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, authenticated, accountId, companyName, vpnAccountId, vpnAccountMismatch
        case vpnRunning, authError, sessionExpired, authErrorKind
    }

    /// `authenticated` and the flags that decide what the menu does are read strictly. The strings
    /// that are only shown (ids, names, a sentence) read as "not stated" when they are not strings,
    /// so a surprising value there never costs the person the whole menu. In an extension so the
    /// memberwise initialiser stays.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = values.lossyInt(forKey: .schemaVersion)
        authenticated = try values.decode(Bool.self, forKey: .authenticated)
        accountId = values.lossy(String.self, forKey: .accountId)
        companyName = values.lossy(String.self, forKey: .companyName)
        vpnAccountId = values.lossy(String.self, forKey: .vpnAccountId)
        vpnAccountMismatch = try values.decodeIfPresent(Bool.self, forKey: .vpnAccountMismatch)
        vpnRunning = try values.decodeIfPresent(Bool.self, forKey: .vpnRunning)
        authError = values.lossy(String.self, forKey: .authError)
        sessionExpired = try values.decodeIfPresent(Bool.self, forKey: .sessionExpired)
        authErrorKind = values.lossy(String.self, forKey: .authErrorKind)
    }
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
     The build the VPN SERVICE is running, which is not always the build of the CLI that asked.

     The service runs the same binary `runos update` replaces, and launchd holds the old inode open,
     so updating leaves the daemon on the previous build until something restarts it. Optional
     because a daemon too old to report it simply omits it, and a version nobody stated cannot be
     compared. See StateStore.vpnRestartRequired.
    */
    let version: String?

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

extension VPNStatus {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, running, accountId, session, clusters, lastPollError
        case interface, address, dns, version
    }

    /// Reads `clusters` as a list, and a null or missing one as empty. A VPN service that has applied
    /// no cluster document yet used to send null, which failed this whole decode: the menu then lost
    /// its cluster rows and the Restart VPN item. `running` and `session` decide what the menu does,
    /// so they are required; everything the app only displays reads as "not stated" when it is null,
    /// missing or of another type. In an extension so the memberwise initialiser stays.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = values.lossyInt(forKey: .schemaVersion)
        running = try values.decode(Bool.self, forKey: .running)
        accountId = values.lossy(String.self, forKey: .accountId)
        session = try values.decode(VPNSession.self, forKey: .session)
        clusters = try values.list(VPNCluster.self, forKey: .clusters)
        lastPollError = values.lossy(String.self, forKey: .lastPollError)
        interface = values.lossy(String.self, forKey: .interface)
        address = values.lossy(String.self, forKey: .address)
        dns = values.lossy(VPNDns.self, forKey: .dns)
        version = values.lossy(String.self, forKey: .version)
    }
}

struct VPNDns: Decodable, Equatable, Sendable {
    let available: Bool
    let mode: String?
    /// The CLI's sentence about the DNS state. With `pending` it is a plain explanation to show
    /// calmly, without it a failure.
    let error: String?
    /*
     The cluster names are not resolvable YET but are being applied, which is the ordinary state for
     a second or two after the first connect. omitted when false by the CLI, and absent on a released
     CLI that predates the field, so nil and false both mean "not pending". It is a state to wait
     through, never an error: see MenuModel.
    */
    let pending: Bool?

    init(available: Bool, mode: String?, error: String?, pending: Bool? = nil) {
        self.available = available
        self.mode = mode
        self.error = error
        self.pending = pending
    }

    private enum CodingKeys: String, CodingKey { case available, mode, error, pending }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        available = try values.flag(forKey: .available)
        mode = values.lossy(String.self, forKey: .mode)
        error = values.lossy(String.self, forKey: .error)
        pending = values.lossy(Bool.self, forKey: .pending)
    }
}

struct VPNSession: Decodable, Equatable, Sendable {
    let present: Bool
    let expiresAt: Date?
    let loginRequired: Bool
}

extension VPNSession {
    private enum CodingKeys: String, CodingKey { case present, expiresAt, loginRequired }

    /// An expiry that cannot be read as a date is "no expiry stated", not a failed status: the
    /// session itself is still described by the flags. In an extension so the memberwise
    /// initialiser stays.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        present = try values.flag(forKey: .present)
        expiresAt = values.lossy(Date.self, forKey: .expiresAt)
        loginRequired = try values.flag(forKey: .loginRequired)
    }
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

extension VPNCluster {
    private enum CodingKeys: String, CodingKey {
        case cid, name, connected, reachable, reason, peerUp, peeredWith
        case endpoint, resolver, zones, rxBytes, txBytes, lastHandshake
    }

    /// `cid` is what every action addresses a cluster by, so it is required. `connected` and
    /// `reachable` decide what is drawn and are flags that read null or missing as false but
    /// reject a value of another type. The rest is display and reads leniently.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cid = try values.decode(String.self, forKey: .cid)
        name = values.lossy(String.self, forKey: .name) ?? ""
        connected = try values.flag(forKey: .connected)
        reachable = try values.flag(forKey: .reachable)
        reason = values.lossy(String.self, forKey: .reason)
        peerUp = try values.flag(forKey: .peerUp)
        peeredWith = values.lossy([String].self, forKey: .peeredWith) ?? []
        endpoint = values.lossy(String.self, forKey: .endpoint)
        resolver = values.lossy(String.self, forKey: .resolver)
        zones = values.lossy([String].self, forKey: .zones)
        rxBytes = values.lossyInt64(forKey: .rxBytes)
        txBytes = values.lossyInt64(forKey: .txBytes)
        lastHandshake = values.lossy(Date.self, forKey: .lastHandshake)
    }
}

/*
 The accounts a login belongs to, from `runos user accounts --json`.

 One login can be a member of several accounts (account sharing), and the CLI switches between
 them with the sign-in it already has. This is read on every refresh while signed in, so the menu
 offers the same list the console does.
*/
struct UserAccountsResult: Decodable, Equatable, Sendable {
    let accounts: [UserAccountEntry]

    private enum CodingKeys: String, CodingKey { case accounts }

    /// No list, or a null one, is no accounts to switch between.
    init(from decoder: Decoder) throws {
        accounts = try decoder.container(keyedBy: CodingKeys.self).list(UserAccountEntry.self, forKey: .accounts)
    }

    init(accounts: [UserAccountEntry]) { self.accounts = accounts }
}

struct UserAccountEntry: Decodable, Equatable, Identifiable, Sendable {
    let aid: String
    let name: String?
    let companyName: String?
    let accountRole: String
    let isDefault: Bool

    var id: String { aid }

    private enum CodingKeys: String, CodingKey { case aid, name, companyName, accountRole, isDefault }

    /// Only the id is needed to switch to an account; the rest is how it is named and described.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        aid = try values.decode(String.self, forKey: .aid)
        name = values.lossy(String.self, forKey: .name)
        companyName = values.lossy(String.self, forKey: .companyName)
        accountRole = values.lossy(String.self, forKey: .accountRole) ?? ""
        isDefault = try values.flag(forKey: .isDefault)
    }

    init(aid: String, name: String?, companyName: String?, accountRole: String, isDefault: Bool) {
        self.aid = aid
        self.name = name
        self.companyName = companyName
        self.accountRole = accountRole
        self.isDefault = isDefault
    }

    /// Company name, then account name, then the bare id: the console's rule, so both name an
    /// account the same way.
    var label: String {
        let company = (companyName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !company.isEmpty { return company }
        let accountName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return accountName.isEmpty ? aid : accountName
    }
}

struct UpdateResult: Decodable, Sendable {
    struct Component: Decodable, Sendable {
        let updated: Bool
        let version: String?
        let message: String?

        private enum CodingKeys: String, CodingKey { case updated, version, message }

        /// `updated` decides whether the desktop relaunches, so it is required and strict. The
        /// version and the message are only shown.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            updated = try values.decode(Bool.self, forKey: .updated)
            version = values.lossy(String.self, forKey: .version)
            message = values.lossy(String.self, forKey: .message)
        }
    }

    let schemaVersion: Int?
    let cli: Component
    let desktop: Component?

    private enum CodingKeys: String, CodingKey { case schemaVersion, cli, desktop }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = values.lossyInt(forKey: .schemaVersion)
        cli = try values.decode(Component.self, forKey: .cli)
        desktop = values.lossy(Component.self, forKey: .desktop)
    }
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
        guard let value, value >= 0 else { return "unknown" }
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

/*
 What `runos update --check --json` answers: is there anything to install, for either component?

 MEASURED 2026-08-31, before the CLI carried a verdict. The payloads for "you are current" and "an
 update is waiting" were identical apart from an English sentence, and for the desktop they were
 byte-identical. So this app could not tell, and its Update RunOS item was always enabled: the only
 way to learn whether anything was waiting was to click it and watch.

 `updateAvailable` is the flag. Everything else here is for display.
*/
struct UpdateCheck: Decodable, Equatable, Sendable {
    struct Component: Decodable, Equatable, Sendable {
        /*
         Absent on an older CLI, and absent must mean "nothing waiting".

         The alternative, treating an unknown as an update, would badge the menu bar on every poll
         against a CLI that simply predates the field, which is worse than never badging it.
        */
        let updateAvailable: Bool?
        /// What is installed now. `version` is the LATEST known version, which is not the same thing.
        let currentVersion: String?
        let version: String?

        var waiting: Bool { updateAvailable == true }

        private enum CodingKeys: String, CodingKey { case updateAvailable, currentVersion, version }

        /// A verdict that is not a boolean is no verdict (nil), never a guess: reading "true" as an
        /// update would badge the menu bar on every poll.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            updateAvailable = values.lossy(Bool.self, forKey: .updateAvailable)
            currentVersion = values.lossy(String.self, forKey: .currentVersion)
            version = values.lossy(String.self, forKey: .version)
        }
    }

    let schemaVersion: Int?
    let cli: Component
    /// Absent when RunOS Desktop is not installed at all.
    let desktop: Component?

    private enum CodingKeys: String, CodingKey { case schemaVersion, cli, desktop }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = values.lossyInt(forKey: .schemaVersion)
        cli = try values.decode(Component.self, forKey: .cli)
        desktop = values.lossy(Component.self, forKey: .desktop)
    }

    /// Either component having something to install is something to install.
    var anyAvailable: Bool { cli.waiting || (desktop?.waiting ?? false) }

    /*
     Whether this CLI answered the question at all.

     An older CLI carries no `updateAvailable` field, and the two cases must not be collapsed. The
     BADGE needs certainty, so an unknown must not light it. The Update ITEM needs the opposite: an
     unknown must leave it clickable, because disabling it would make a desktop that shipped ahead
     of the CLI permanently unable to update itself, which is worse than the behaviour it replaced.
    */
    var verdictKnown: Bool { cli.updateAvailable != nil || desktop?.updateAvailable != nil }
}

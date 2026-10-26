import XCTest
@testable import RunOSDesktop

/*
 EVERY COMBINATION OF STATE, THROUGH THE REAL MENU FUNCTION.

 The menu is `MenuModel.build(store:...)`, a pure function of the state. This runs the cross product
 of everything that changes what the menu says (CLI health, sign-in, VPN service, build drift,
 clusters, a running operation, DNS, an error, an update, an unreadable VPN status) and asserts what
 must be true in ALL of them:

   1. no text appears twice at the top level, or twice inside one submenu   (FCR 1726)
   2. Sign In is shown exactly when a sign-in is required
   3. Restart VPN is always shown, and enabled whenever no other action runs   (FCR 1730)
   4. while an operation runs, nothing that starts another action is enabled
   5. every disabled item has its reason somewhere in view
   6. a state with no VPN status always says why; the menu is never silently bare   (FCR 1730)
   7. a pending DNS is a calm line and never an error
   8. no menu line is longer than a line, and what was shortened is reachable through Show Details
   9. item ids are unique, because SwiftUI draws the list by them

 The function runs with its duplicate safety net OFF, so a state that would repeat a text fails here
 instead of being hidden from the person by the net.
*/
@MainActor
final class MenuStateMatrixTests: XCTestCase {

    // MARK: the dimensions

    enum CLI: CaseIterable { case missing, outdated, ok, development }
    enum Auth: CaseIterable { case signedIn, signedOut, endingSoon, expired }
    enum Service: CaseIterable { case missing, running, notRunning }
    enum Drift: CaseIterable { case none, drift, unknown }
    enum Clusters: CaseIterable { case none, one, many, dead }
    enum Busy: CaseIterable { case none, signIn, connect, renew, install, restart, update }
    enum DNS: CaseIterable { case ok, pending, failed }
    enum Failure: CaseIterable { case none, short, long }
    enum UpdateState: CaseIterable { case none, available, unknown }
    enum Problem: CaseIterable { case none, unreadable }

    struct Scenario: CustomStringConvertible {
        var cli: CLI, auth: Auth, service: Service, drift: Drift, clusters: Clusters
        var busy: Busy, dns: DNS, failure: Failure, update: UpdateState, problem: Problem
        var description: String {
            "cli=\(cli) auth=\(auth) service=\(service) drift=\(drift) clusters=\(clusters) busy=\(busy) dns=\(dns) failure=\(failure) update=\(update) problem=\(problem)"
        }
    }

    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    static let cliVersion = "1.22.2"
    static let longError = "Error: private DNS zone example.test could not be applied. This is usually timing rather than a broken cluster. Run `runos vpn connect c-example1` again in a few seconds, and if it keeps failing run `runos vpn diagnose` and send what it prints to support."

    static func operationMessage(_ busy: Busy) -> String? {
        switch busy {
        case .none: return nil
        case .signIn: return SignInPurpose.signIn.finishingMessage
        case .connect: return SignInPurpose.confirm.busyMessage
        case .renew: return SignInPurpose.renew.busyMessage
        case .install: return "Installing the RunOS VPN service…"
        case .restart: return "Restarting the VPN service…"
        case .update: return "Updating RunOS…"
        }
    }

    /// Builds the store a refresh would have left behind for this scenario. Combinations that cannot
    /// occur (a missing CLI with a status to show) collapse to the state that can.
    static func makeStore(_ s: Scenario) -> StateStore {
        let store = StateStore()
        store.cliAvailable = s.cli != .missing
        store.cliOutdated = s.cli == .outdated
        store.cliDevelopment = s.cli == .development
        store.cliVersion = s.cli == .missing ? nil : (s.cli == .development ? "dev-2026-10-26T09:00:00Z" : cliVersion)
        store.updateAvailable = s.update == .available
        store.updateVerdictKnown = s.update == .unknown ? nil : true

        switch s.failure {
        case .none: store.errorMessage = nil
        case .short: store.errorMessage = "the VPN daemon is not answering"
        case .long: store.errorMessage = longError
        }
        if s.cli == .missing {
            store.errorMessage = "RunOS Desktop cannot find the RunOS CLI. Install or update the CLI, then run 'runos desktop install'."
            return store
        }
        if s.cli == .outdated {
            store.errorMessage = "RunOS Desktop requires CLI 1.15.0 or newer. Run 'runos update'."
        }

        let signedIn = s.auth == .signedIn || s.auth == .endingSoon
        store.cliStatus = CLIStatus(
            schemaVersion: 1, authenticated: signedIn, accountId: "acct-example", companyName: "Example Co",
            vpnAccountId: nil, vpnAccountMismatch: nil, vpnRunning: nil, authError: nil,
            sessionExpired: s.auth == .expired ? true : nil, authErrorKind: signedIn ? nil : "rejected")
        if signedIn {
            store.accounts = [
                UserAccountEntry(aid: "acct-example", name: "Example", companyName: "Example Co", accountRole: "owner", isDefault: true),
                UserAccountEntry(aid: "acct-other", name: "Other", companyName: "Other Co", accountRole: "member", isDefault: false),
            ]
        }

        switch s.service {
        case .missing:
            store.vpnServiceMissing = true
            store.vpnStatus = nil
        case .running, .notRunning:
            let running = s.service == .running
            let loginRequired = !signedIn
            let expires: Date? = s.auth == .endingSoon ? now.addingTimeInterval(30 * 60) : now.addingTimeInterval(20 * 3600)
            let version: String? = {
                switch s.drift {
                case .none: return store.cliVersion
                case .drift: return "1.20.0"
                case .unknown: return nil
                }
            }()
            let dns: VPNDns? = {
                guard running else { return nil }
                switch s.dns {
                case .ok: return VPNDns(available: true, mode: "resolver-files", error: nil)
                case .pending: return VPNDns(available: false, mode: "resolver-files",
                                             error: "Cluster names are still being applied by macOS.", pending: true)
                case .failed: return VPNDns(available: false, mode: "resolver-files",
                                            error: "could not write the resolver file: permission denied")
                }
            }()
            store.vpnStatus = VPNStatus(
                schemaVersion: 1, running: running, accountId: "acct-example",
                session: VPNSession(present: signedIn, expiresAt: signedIn ? expires : nil, loginRequired: loginRequired),
                clusters: running ? clusters(s.clusters) : [], lastPollError: nil,
                interface: nil, address: nil, dns: dns, version: version)
        }

        if s.problem == .unreadable, s.service != .missing {
            store.vpnStatus = nil
            store.vpnStatusProblem = .unreadable(ReadFailure(
                headline: "Cannot read the VPN status", reason: "the field \"session\" is missing."))
        }

        store.operationMessage = operationMessage(s.busy)
        store.isUpdating = s.busy == .update
        return store
    }

    static func clusters(_ kind: Clusters) -> [VPNCluster] {
        func cluster(_ cid: String, connected: Bool, reachable: Bool) -> VPNCluster {
            VPNCluster(cid: cid, name: "Cluster \(cid)", connected: connected, reachable: reachable,
                       reason: reachable ? nil : "no VPN server for this cluster", peerUp: reachable, peeredWith: [],
                       endpoint: nil, resolver: nil, zones: nil, rxBytes: nil, txBytes: nil, lastHandshake: nil)
        }
        switch kind {
        case .none: return []
        case .one: return [cluster("c-one", connected: true, reachable: true)]
        case .many: return [cluster("c-one", connected: true, reachable: true),
                            cluster("c-two", connected: false, reachable: true),
                            cluster("c-three", connected: true, reachable: true)]
        case .dead: return [cluster("c-dead", connected: true, reachable: false),
                            cluster("c-live", connected: true, reachable: true)]
        }
    }

    static func layout(_ store: StateStore, dedupe: Bool = false, loginItemError: String? = nil) -> MenuLayout {
        MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                        loginItemError: loginItemError, now: now, dedupe: dedupe)
    }

    /// The full cross product of the dimensions that change the menu. The CLI dimension (which
    /// changes only a few lines) is rotated through, so every CLI health meets every other value.
    static func allScenarios() -> [Scenario] {
        var all: [Scenario] = []
        var counter = 0
        for auth in Auth.allCases { for service in Service.allCases { for drift in Drift.allCases
        { for clusters in Clusters.allCases { for busy in Busy.allCases { for dns in DNS.allCases
        { for failure in Failure.allCases { for update in UpdateState.allCases { for problem in Problem.allCases {
            let cli = CLI.allCases[counter % CLI.allCases.count]
            counter += 1
            all.append(Scenario(cli: cli, auth: auth, service: service, drift: drift, clusters: clusters,
                                busy: busy, dns: dns, failure: failure, update: update, problem: problem))
        } } } } } } } } }
        // And every CLI health against a plain healthy state, so none is only ever seen rotated.
        for cli in CLI.allCases {
            all.append(Scenario(cli: cli, auth: .signedIn, service: .running, drift: .none, clusters: .one,
                                busy: .none, dns: .ok, failure: .none, update: .none, problem: .none))
        }
        return all
    }

    // MARK: helpers

    private func topLevelShownText(_ layout: MenuLayout) -> [String] {
        layout.items.compactMap(\.shownText)
    }

    private func isReasonInView(_ reason: DisabledReason, item: MenuItem, layout: MenuLayout, store: StateStore) -> Bool {
        switch reason {
        case .operationRunning:
            guard let operation = store.operationMessage else { return false }
            return topLevelShownText(layout).contains(operation)
        case .signInRequired:
            return layout.items.contains { $0.action == .signIn }
        case .serviceMissing:
            return layout.items.contains { $0.id == "status.service-missing" }
                && layout.items.contains { $0.action == .installVPNService }
        case .statusUnavailable:
            return layout.items.contains { $0.id == "status.error" || $0.id == "status.reading" || $0.id == "status.vpn-problem" }
        case .saysItself:
            return item.isOn || ["RunOS Is Up to Date", "Checking for Updates…"].contains(item.title)
        case .noTunnel:
            guard let vpn = layout.item("vpn"), case .submenu(let children) = vpn.kind else { return false }
            return children.contains { $0.id == "vpn.connect" || $0.id == "vpn.signed-out" }
        }
    }

    // MARK: the invariants

    func testInvariantsHoldInEveryCombinationOfState() {
        let scenarios = Self.allScenarios()
        XCTAssertGreaterThan(scenarios.count, 50_000, "the matrix must really be the cross product")
        var failures = 0
        for scenario in scenarios {
            let store = Self.makeStore(scenario)
            let layout = Self.layout(store)
            let problems = violations(scenario, store, layout)
            if !problems.isEmpty {
                failures += 1
                if failures <= 8 { XCTFail("\(scenario)\n  " + problems.joined(separator: "\n  ")) }
            }
        }
        XCTAssertEqual(failures, 0, "\(failures) of \(scenarios.count) combinations broke an invariant")
    }

    private func violations(_ scenario: Scenario, _ store: StateStore, _ layout: MenuLayout) -> [String] {
        var out: [String] = []

        // 1. no text twice, at the top level or inside any submenu.
        func duplicates(_ items: [MenuItem], _ where_: String) {
            let texts = items.compactMap(\.shownText)
            let repeated = Dictionary(grouping: texts, by: { $0 }).filter { $0.value.count > 1 }.keys
            if !repeated.isEmpty { out.append("repeated text in \(where_): \(repeated.sorted())") }
            let ids = items.map(\.id)
            if Set(ids).count != ids.count { out.append("repeated ids in \(where_)") }
            for item in items { if case .submenu(let children) = item.kind { duplicates(children, item.id) } }
        }
        duplicates(layout.items, "top level")

        // 2. Sign In exactly when a sign-in is required.
        let signInShown = layout.items.contains { $0.action == .signIn }
        if signInShown != store.signInRequired { out.append("Sign In shown=\(signInShown) but signInRequired=\(store.signInRequired)") }

        // 3. Restart VPN is ALWAYS in the menu (a service that looks current can still be stuck),
        //    enabled whenever no other action runs, and disabled only by the running operation.
        if let restart = layout.items.first(where: { $0.action == .restartVPN }) {
            if restart.enabled == store.isBusy { out.append("Restart VPN enabled=\(restart.enabled) while busy=\(store.isBusy)") }
            if !restart.enabled && restart.disabledReason != .operationRunning { out.append("Restart VPN disabled for the wrong reason") }
            if restart.title != "Restart VPN" { out.append("Restart VPN is titled \(restart.title)") }
        } else {
            out.append("Restart VPN is missing")
        }
        // The drift hint is extra information: present exactly when the builds differ.
        let hint = layout.items.contains { $0.id == "status.restart-hint" }
        if hint != store.vpnRestartRequired { out.append("restart hint shown=\(hint) but drift=\(store.vpnRestartRequired)") }

        // 4. nothing that starts an action is enabled while busy.
        if store.isBusy {
            for item in layout.allItems where item.enabled {
                if let action = item.action, action.startsAnAction { out.append("\(item.id) is enabled while busy") }
            }
        }

        // 5. every disabled item has a reason, and the reason is in view.
        for item in layout.allItems where !item.enabled && item.kind != .divider {
            guard let reason = item.disabledReason else { out.append("\(item.id) is disabled with no reason"); continue }
            if !isReasonInView(reason, item: item, layout: layout, store: store) {
                out.append("\(item.id) is disabled for \(reason) but that is not in view")
            }
        }

        // 6. never a silently bare menu.
        if store.cliStatus != nil, store.vpnStatus == nil, !store.vpnServiceMissing, !store.isBusy,
           !layout.items.contains(where: { ["status.vpn-problem", "status.error", "status.reading-vpn"].contains($0.id) }) {
            out.append("no VPN status and nothing says why")
        }
        if store.cliStatus == nil, !store.isBusy,
           !layout.items.contains(where: { ["status.error", "status.reading"].contains($0.id) }) {
            out.append("no RunOS status and nothing says why")
        }

        // 7. pending DNS: a calm line, never an error line.
        let pendingLine = layout.items.contains { $0.id == "status.dns-pending" }
        if pendingLine != store.dnsPending { out.append("pending line shown=\(pendingLine) but dnsPending=\(store.dnsPending)") }
        if pendingLine && layout.items.contains(where: { $0.id == "status.dns-failure" }) { out.append("pending shown beside a DNS failure") }

        // 8. text lines are one short line; what was shortened is behind Show Details.
        for item in layout.items where item.kind == .text {
            if item.title.contains("\n") { out.append("\(item.id) has a newline") }
            if item.title.count > ErrorPresentation.menuLineLimit { out.append("\(item.id) is \(item.title.count) characters") }
        }
        let detailsShown = layout.items.contains { $0.action == .showDetails }
        if detailsShown != (layout.details != nil) { out.append("Show Details and the details text disagree") }
        if let error = store.errorMessage, ErrorPresentation.menuLine(error).isSummary {
            if !detailsShown { out.append("a shortened error has no Show Details") }
            if layout.details?.contains(ErrorPresentation.fullText(error)) != true { out.append("the details lack the whole error") }
        }

        // 9. the stable parts are always there.
        for id in ["vpn", "update", "connection-status", "about", "quit"] where layout.item(id) == nil {
            out.append("\(id) is missing")
        }
        return out
    }

    func testTheMatrixCoversWhatItClaims() {
        let scenarios = Self.allScenarios()
        XCTAssertTrue(scenarios.contains { $0.cli == .missing })
        XCTAssertTrue(scenarios.contains { $0.cli == .outdated })
        XCTAssertTrue(scenarios.contains { $0.cli == .development })
        XCTAssertTrue(scenarios.contains { $0.auth == .endingSoon && $0.busy == .renew })
        XCTAssertTrue(scenarios.contains { $0.problem == .unreadable && $0.drift == .drift })
        XCTAssertTrue(scenarios.contains { $0.dns == .pending && $0.service == .running })
        XCTAssertEqual(Set(scenarios.map { "\($0.cli)" }).count, 4)
    }

    // MARK: the safety net

    /// The app builds with a net that drops a repeated text. The matrix above runs with it OFF, so it
    /// proves the logic needs no net; this proves the net does its one job should one ever be needed.
    func testTheSafetyNetDropsARepeatedTextButTheLogicNeedsNoNet() {
        let store = Self.makeStore(Scenario(cli: .ok, auth: .signedIn, service: .running, drift: .none, clusters: .one,
                                            busy: .none, dns: .ok, failure: .short, update: .none, problem: .none))
        store.noticeMessage = store.errorMessage // the same words twice
        let sentence = "the VPN daemon is not answering"
        XCTAssertEqual(Self.layout(store, dedupe: false).items.filter { $0.title == sentence }.count, 2)
        XCTAssertEqual(Self.layout(store, dedupe: true).items.filter { $0.title == sentence }.count, 1)
    }

    // MARK: the matrix is not vacuous

    func testTheMatrixReallyProducesDisabledItemsAndReasons() {
        var disabled = 0
        var reasons = Set<String>()
        for (index, scenario) in Self.allScenarios().enumerated() where index % 25 == 0 {
            let layout = Self.layout(Self.makeStore(scenario))
            for item in layout.allItems where !item.enabled && item.kind != .divider {
                disabled += 1
                reasons.insert("\(item.disabledReason.map { "\($0)" } ?? "none")")
            }
        }
        XCTAssertGreaterThan(disabled, 1000)
        XCTAssertTrue(reasons.isSuperset(of: ["operationRunning", "signInRequired", "saysItself"]), "\(reasons)")
    }
}

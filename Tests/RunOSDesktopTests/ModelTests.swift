import Combine
import AppKit
import XCTest
@testable import RunOSDesktop

final class ModelTests: XCTestCase {
    func testCLIStatusDecoderKeepsCompanyName() throws {
        let data = Data(#"{"schemaVersion":1,"authenticated":true,"accountId":"acct","companyName":"Example Company"}"#.utf8)
        let result = try JSONDecoder.runOS.decode(CLIStatus.self, from: data)

        XCTAssertEqual(result.companyName, "Example Company")
    }

    func testVPNStatusDecoderKeepsUnreachableReasonAndPeering() throws {
        let data = Data(#"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[{"cid":"c1","name":"One","connected":true,"reachable":false,"reason":"no server","peerUp":false,"peeredWith":["c2"]}]}"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)
        XCTAssertEqual(result.clusters.first?.reason, "no server")
        XCTAssertEqual(result.clusters.first?.peeredWith, ["c2"])
    }

    func testConnectableClustersExcludeUnavailableVPNs() throws {
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"ready","name":"Ready","connected":false,"reachable":true,"peerUp":false,"peeredWith":[]},{"cid":"active","name":"Active","connected":true,"reachable":false,"peerUp":true,"peeredWith":[]},{"cid":"missing","name":"Missing","connected":false,"reachable":false,"reason":"no VPN server installed","peerUp":false,"peeredWith":[]}] }"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)

        // "active" stays in the LIST on purpose: it is connected-but-dead, and the menu is the
        // only place a person can switch it off, so hiding it would trap them in that state.
        XCTAssertEqual(result.connectableClusters.map(\.cid), ["ready", "active"])
        // ...but it is NOT a working connection, and nothing may present it as one.
        XCTAssertFalse(result.hasWorkingConnection)
        XCTAssertEqual(result.deadConnections.map(\.cid), ["active"])
    }

    /*
     The reported defect, in the operator's words: "right now it says i am connected, but theres
     nothing on the other side, this is wrong".

     A cluster that is in the connected set but whose VPN server is missing carries connected:true
     and reachable:false. The menu drew it as an ordinary ticked toggle and the menu bar showed the
     connected icon, so both surfaces asserted a working tunnel over a cluster that routes nothing.
     */
    func testADeadConnectionIsNeverPresentedAsWorking() throws {
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"vhm-lab","connected":true,"reachable":false,"reason":"no VPN server installed","peerUp":false,"peeredWith":[]}] }"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)

        XCTAssertFalse(result.hasWorkingConnection, "a cluster with no VPN server is not a working connection")
        XCTAssertTrue(result.clusters[0].isDeadConnection)

        // The label a person reads must carry the trouble, not just the name.
        let label = MenuPresentation.clusterLabel(result.clusters[0])
        XCTAssertTrue(label.contains("vhm-lab"), "keeps the name, got \(label)")
        XCTAssertTrue(label.contains("no VPN server installed"), "must say why it is not working, got \(label)")
    }

    func testAWorkingConnectionIsLabelledPlainly() throws {
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"vhm-lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}] }"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)

        XCTAssertTrue(result.hasWorkingConnection)
        XCTAssertFalse(result.clusters[0].isDeadConnection)
        XCTAssertEqual(MenuPresentation.clusterLabel(result.clusters[0]), "vhm-lab (a1b)")
    }

    /*
     The only thing an account difference may ever put in front of a person.

     The app follows the account you are signed in to by itself. When Conductor wants a fresh
     sign-in it cannot, and then this is said: a thing to do, naming the account it is for, and
     never the two-account state behind it.
    */
    func testSignInPromptAsksForTheOneThingAPersonCanDo() {
        let prompt = MenuPresentation.signInPrompt(account: "abcde")

        XCTAssertTrue(prompt.contains("abcde"), "names the account it is for, got \(prompt)")
        XCTAssertTrue(prompt.lowercased().contains("sign in"), "asks for a sign-in, got \(prompt)")
        // None of the internals the old message leaked.
        XCTAssertFalse(prompt.lowercased().contains("mismatch"), "got \(prompt)")
        XCTAssertFalse(prompt.lowercased().contains("cli"), "got \(prompt)")
        XCTAssertFalse(prompt.lowercased().contains("still signed in"), "got \(prompt)")
    }

    func testSignInPromptSurvivesAnUnknownAccount() {
        let prompt = MenuPresentation.signInPrompt(account: nil)

        XCTAssertFalse(prompt.contains("nil"), "got \(prompt)")
        XCTAssertFalse(prompt.isEmpty)
    }

    @MainActor
    func testMenuBarStateDerivation() {
        let store = StateStore()
        XCTAssertEqual(store.menuBarState, .off)
        store.errorMessage = "problem"
        XCTAssertEqual(store.menuBarState, .attention)
        store.errorMessage = nil
        // Running with a cluster that is genuinely up is the ONLY thing that earns the connected
        // icon. The tunnel being up carries no promise on its own.
        store.vpnStatus = try? JSONDecoder.runOS.decode(VPNStatus.self, from: Data(#"{"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#.utf8))
        XCTAssertEqual(store.menuBarState, .connected)
    }

    /*
     The icon half of the same defect. `running` means the tunnel interface is up; it says nothing
     about whether any cluster is on the other side. Showing the connected icon for a tunnel that
     reaches nothing is the menu bar making a claim it cannot support.
     */
    @MainActor
    func testMenuBarDoesNotClaimConnectedWhenNothingIsReachable() {
        let store = StateStore()

        store.vpnStatus = try? JSONDecoder.runOS.decode(VPNStatus.self, from: Data(#"{"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"lab","connected":true,"reachable":false,"reason":"no VPN server installed","peerUp":false,"peeredWith":[]}]}"#.utf8))
        XCTAssertEqual(store.menuBarState, .attention, "connected to a cluster that routes nothing is a problem, not a connection")

        store.vpnStatus = try? JSONDecoder.runOS.decode(VPNStatus.self, from: Data(#"{"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#.utf8))
        XCTAssertNotEqual(store.menuBarState, .connected, "a tunnel connected to no cluster is not a connection")
    }

    @MainActor
    func testMenuBarStartsWithDisconnectedIcon() {
        let store = StateStore()

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(
                state: store.menuBarState,
                isActive: store.isBusy,
                reduceMotion: false,
                frame: 0
            ),
            "MenuBarIconOff"
        )
    }

    @MainActor
    func testUpdateActionShowsProgressWhileUpdateRuns() {
        let store = StateStore()
        XCTAssertEqual(store.updateActionTitle, "Update RunOS")

        store.operationMessage = "Updating RunOS…"

        XCTAssertEqual(store.updateActionTitle, "Updating RunOS…")
    }

    func testCommandConstruction() {
        XCTAssertEqual(DesktopCommands.setVPN(enabled: false), ["vpn", "down", "--json"])
        XCTAssertEqual(DesktopCommands.setCluster("cid", connected: false), ["vpn", "connect", "cid", "--json"])
        // Disconnecting the LAST cluster must NOT end the session: 'down' here forced a fresh
        // browser sign-in on every reconnect for a single-cluster account. Sign Out is the only
        // command that ends the session.
        XCTAssertEqual(
            DesktopCommands.toggleCluster("cid", isConnected: true),
            ["vpn", "disconnect", "cid", "--json"]
        )
        XCTAssertEqual(
            DesktopCommands.toggleCluster("cid", isConnected: false),
            ["vpn", "connect", "cid", "--json"]
        )
    }

    func testVPNClusterLabelIncludesCID() {
        XCTAssertEqual(MenuPresentation.clusterLabel(name: "vhm-lab", cid: "a1b"), "vhm-lab (a1b)")
        XCTAssertEqual(MenuPresentation.clusterLabel(name: "", cid: "a1b"), "a1b")
    }

    func testVersionComparison() {
        XCTAssertTrue(VersionComparator.isOlder("1.14.9", than: "1.15.0"))
        XCTAssertFalse(VersionComparator.isOlder("v1.15.0", than: "1.15.0"))
        XCTAssertFalse(VersionComparator.isOlder("2.0.0", than: "1.15.0"))
    }

    func testCLIVersionCompatibility() {
        XCTAssertEqual(VersionComparator.compatibility("1.14.9", minimum: "1.15.0"), .outdated)
        XCTAssertEqual(VersionComparator.compatibility("v1.15.0", minimum: "1.15.0"), .supported)
        XCTAssertEqual(VersionComparator.compatibility("dev-2026-08-16T22:54:06Z", minimum: "1.15.0"), .development)
        XCTAssertEqual(VersionComparator.compatibility("unexpected", minimum: "1.15.0"), .invalid)
    }

    func testMenuBarActivityFramesCycleDuringActions() {
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: .off, isActive: false, reduceMotion: false, frame: 2),
            "MenuBarIconOff"
        )
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: .connected, isActive: false, reduceMotion: false, frame: 2),
            "MenuBarIcon"
        )
        XCTAssertEqual(
            (0..<4).map {
                MenuBarIconAnimation.imageName(state: .attention, isActive: true, reduceMotion: false, frame: $0)
            },
            ["MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3", "MenuBarActivity1"]
        )
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: .attention, isActive: true, reduceMotion: true, frame: 2),
            "MenuBarIcon"
        )
    }

    @MainActor
    func testMenuBarActivityIconsHaveRetinaResolution() throws {
        for name in ["MenuBarIconOff", "MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3"] {
            let icon = try XCTUnwrap(NSImage(named: name))
            let largestWidth = icon.representations.map(\.pixelsWide).max()

            XCTAssertGreaterThanOrEqual(largestWidth ?? 0, 36)
        }
    }

    func testDisconnectedMenuBarIconHasReducedAlpha() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assets = repository.appending(path: "Sources/RunOSDesktop/Assets.xcassets")
        let connected = assets.appending(path: "MenuBarIcon.imageset/MenuBarIcon.png")
        let disconnected = assets.appending(path: "MenuBarIconOff.imageset/MenuBarIconOff.png")

        XCTAssertEqual(try maximumAlpha(at: connected), 255)
        XCTAssertEqual(try maximumAlpha(at: disconnected), 140)
    }

    @MainActor
    func testAboutPresenterPassesCurrentDetails() {
        var presentedDetails: AboutDetails?
        let presenter = AboutPresenter { details in
            presentedDetails = details
        }
        let details = AboutDetails(
            desktopVersion: "1.2.3",
            cliVersion: "dev-build",
            accountId: "account-a",
            companyName: "Example Company",
            vpn: nil,
            trafficSlots: [],
            trafficTotal: 0
        )

        presenter.show(details)

        XCTAssertEqual(presentedDetails, details)
    }

    func testAboutLayoutKeepsContentAwayFromWindowEdges() {
        XCTAssertGreaterThanOrEqual(AboutLayout.panelWidth - AboutLayout.contentWidth, 56)
    }

    @MainActor
    func testAboutIconHasNativeResolution() throws {
        let icon = try XCTUnwrap(NSImage(named: "AboutIcon"))
        let largestWidth = icon.representations.map(\.pixelsWide).max()

        XCTAssertGreaterThanOrEqual(largestWidth ?? 0, 100)
    }

    @MainActor
    func testCoordinatorPublishesStoreChanges() {
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: nil)
        var notificationCount = 0
        let observation = coordinator.objectWillChange.sink {
            notificationCount += 1
        }

        store.errorMessage = "problem"

        XCTAssertEqual(notificationCount, 1)
        withExtendedLifetime(observation) {}
    }

    private func maximumAlpha(at url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        var maximum = 0

        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                var samples = [Int](repeating: 0, count: 4)
                image.getPixel(&samples, atX: x, y: y)
                maximum = max(maximum, samples[3])
            }
        }

        return maximum
    }
}

extension ModelTests {
    func testVPNStatusDecodesNetworkStats() throws {
        let json = """
        {"schemaVersion":2,"running":true,"interface":"utun0","address":"10.10.0.3/32",
         "session":{"present":true,"loginRequired":false},
         "dns":{"available":true,"mode":"native","error":""},
         "clusters":[{"cid":"c2d","name":"host-homelab","connected":true,"reachable":true,
           "endpoint":"192.168.10.20:32768","resolver":"10.20.0.2","peerUp":true,"peeredWith":[],
           "rxBytes":12345,"txBytes":67890,"lastHandshake":"2026-08-24T11:44:22+02:00"}]}
        """.data(using: .utf8)!
        let status = try JSONDecoder.runOS.decode(VPNStatus.self, from: json)
        XCTAssertEqual(status.interface, "utun0")
        XCTAssertEqual(status.dns?.mode, "native")
        XCTAssertEqual(status.clusters[0].endpoint, "192.168.10.20:32768")
        XCTAssertEqual(status.clusters[0].rxBytes, 12345)
        XCTAssertNotNil(status.clusters[0].lastHandshake)
    }

    func testVPNStatusDecodesWithoutStats() throws {
        // An older CLI omits every stats field; the app must keep working against it.
        let json = """
        {"running":false,"session":{"present":false,"loginRequired":true},"clusters":[]}
        """.data(using: .utf8)!
        let status = try JSONDecoder.runOS.decode(VPNStatus.self, from: json)
        XCTAssertNil(status.interface)
        XCTAssertNil(status.dns)
    }

    func testStatsFormattingBytesAndHandshake() {
        XCTAssertEqual(StatsFormatting.bytes(nil), "—")
        XCTAssertEqual(StatsFormatting.bytes(0), "Zero KB")
        XCTAssertTrue(StatsFormatting.bytes(222_298_112).contains("MB"))
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        XCTAssertEqual(StatsFormatting.handshake(nil, now: now), "never")
        XCTAssertEqual(StatsFormatting.handshake(Date(timeIntervalSince1970: 0), now: now), "never")
        XCTAssertEqual(StatsFormatting.handshake(now.addingTimeInterval(-42), now: now), "42s ago")
        XCTAssertEqual(StatsFormatting.handshake(now.addingTimeInterval(-7200), now: now), "2h ago")
    }
}

extension ModelTests {
    func testTrafficSamplerBucketsDeltasIntoFiveMinuteSlots() {
        var sampler = TrafficSampler()
        let base = Date(timeIntervalSince1970: 1_787_000_100) // inside some 5-minute bucket
        sampler.record(total: 1000, at: base)                  // first sample only sets the floor
        sampler.record(total: 1600, at: base.addingTimeInterval(30))
        sampler.record(total: 1900, at: base.addingTimeInterval(60))
        XCTAssertEqual(sampler.buckets.count, 1)
        XCTAssertEqual(sampler.buckets[0].bytes, 900)
        sampler.record(total: 2900, at: base.addingTimeInterval(400))
        XCTAssertEqual(sampler.buckets.count, 2)
        XCTAssertEqual(sampler.buckets[1].bytes, 1000)
    }

    func testTrafficSamplerSurvivesACounterReset() {
        var sampler = TrafficSampler()
        let base = Date(timeIntervalSince1970: 1_787_000_100)
        sampler.record(total: 5000, at: base)
        // The peer was re-added and WireGuard's counter started over: the new total IS the delta.
        sampler.record(total: 300, at: base.addingTimeInterval(30))
        XCTAssertEqual(sampler.buckets[0].bytes, 300)
    }

    func testTrafficSamplerSlotsAlignToTheWallClockWithGaps() {
        var sampler = TrafficSampler()
        let base = Date(timeIntervalSince1970: 1_787_000_100)
        sampler.record(total: 0, at: base)
        sampler.record(total: 500, at: base.addingTimeInterval(30))
        // The Mac slept for twenty minutes; the next sample lands four buckets later.
        let later = base.addingTimeInterval(20 * 60)
        sampler.record(total: 900, at: later)
        let slots = sampler.hourSlots(now: later)
        XCTAssertEqual(slots.count, 12)
        XCTAssertEqual(slots[11], 400)
        XCTAssertEqual(slots[7], 500)
        XCTAssertEqual(slots[8...10].reduce(0, +), 0)
        XCTAssertEqual(sampler.hourSlots(now: later).reduce(0, +), 900)
    }

    func testTrafficSamplerKeepsOnlyAnHour() {
        var sampler = TrafficSampler()
        var clock = Date(timeIntervalSince1970: 1_787_000_100)
        sampler.record(total: 0, at: clock)
        for step in 1...20 {
            clock = clock.addingTimeInterval(300)
            sampler.record(total: Int64(step) * 100, at: clock)
        }
        XCTAssertEqual(sampler.buckets.count, TrafficSampler.capacity)
    }
}

extension ModelTests {
    func testPingVerdictParsesAverageAndFailure() {
        let ok = ConnectionDiagnostics.pingVerdict(
            exitCode: 0,
            output: "2 packets transmitted, 2 packets received, 0.0% packet loss\nround-trip min/avg/max/stddev = 1.177/1.377/1.577/nan ms\n"
        )
        XCTAssertTrue(ok.reachable)
        XCTAssertEqual(ok.detail, "1.377 ms")
        let dead = ConnectionDiagnostics.pingVerdict(exitCode: 2, output: "")
        XCTAssertFalse(dead.reachable)
        XCTAssertEqual(dead.detail, "no reply")
    }

    func testResolvedAddressesAndPrivacy() {
        let output = "name: k8s.c2d.abcde.dev.runos.xyz\nip_address: 10.20.0.1\nip_address: 10.20.0.2\n"
        XCTAssertEqual(ConnectionDiagnostics.resolvedAddresses(output), ["10.20.0.1", "10.20.0.2"])
        XCTAssertEqual(ConnectionDiagnostics.resolvedAddresses("no such name\n"), [])
        XCTAssertTrue(ConnectionDiagnostics.isPrivateIPv4("10.20.0.1"))
        XCTAssertTrue(ConnectionDiagnostics.isPrivateIPv4("192.168.10.20"))
        XCTAssertTrue(ConnectionDiagnostics.isPrivateIPv4("172.20.0.9"))
        XCTAssertFalse(ConnectionDiagnostics.isPrivateIPv4("203.0.113.9"))
        XCTAssertFalse(ConnectionDiagnostics.isPrivateIPv4("not-an-ip"))
    }
}

/*
 Two defects reported together, 2026-08-25, from one screenshot of the Connection Status window:
 every ping row was a wall of raw ping stdout, and nothing anywhere said WHY they were all failing.

 The cause of the failures was an expired VPN session: `runos vpn status --json` carried
 session {present: false, loginRequired: true}, the tunnel interface was still up, and the cluster
 still read connected: true. So the app presented a working VPN that routed nothing, and the only
 hint was a tinted menu-bar icon.
*/
extension ModelTests {
    func testPingFailureIsOneShortLineNotTheWholeDump() {
        // The screenshot: "PING 10.x.x.x: 56 data bytes / Request timeout for icmp_seq 0 / --- ping
        // statistics --- / 2 packets transmitted, 0 packets received, 100.0% packet loss" in the
        // detail column of one row. `pingVerdict` already returns "no reply" for this; the
        // production path never reached it, because CLIRunner.run THROWS on a nonzero exit and the
        // catch used error.localizedDescription, which is the whole dump.
        let dump = """
        PING 198.51.100.7 (198.51.100.7): 56 data bytes
        Request timeout for icmp_seq 0

        --- 198.51.100.7 ping statistics ---
        2 packets transmitted, 0 packets received, 100.0% packet loss
        """
        XCTAssertEqual(ConnectionDiagnostics.concise(dump), "PING 198.51.100.7 (198.51.100.7): 56 data bytes")
        XCTAssertFalse(ConnectionDiagnostics.concise(dump).contains("\n"))
    }

    func testConciseCapsALongSingleLineAndSurvivesEmptyInput() {
        let long = String(repeating: "x", count: 400)
        XCTAssertLessThanOrEqual(ConnectionDiagnostics.concise(long).count, 80)
        XCTAssertTrue(ConnectionDiagnostics.concise(long).hasSuffix("…"))
        XCTAssertEqual(ConnectionDiagnostics.concise("   \n\n  "), "failed")
        XCTAssertEqual(ConnectionDiagnostics.concise("\n\nreal reason\nnoise"), "real reason")
    }

    func testAFailedPingReadsAsNoReply() {
        // What the row must say once the verdict is actually consulted.
        let verdict = ConnectionDiagnostics.pingVerdict(
            exitCode: 2,
            output: "PING 198.51.100.7: 56 data bytes\nRequest timeout for icmp_seq 0\n"
        )
        XCTAssertFalse(verdict.reachable)
        XCTAssertEqual(verdict.detail, "no reply")
    }

    func testExpiredVPNSessionIsReportedAsTheReason() throws {
        // The diagnostics must not run a dozen pings that CANNOT pass and leave the person to infer
        // why. An expired session is the answer, and it is knowable before the first packet.
        let expired = VPNSession(present: false, expiresAt: nil, loginRequired: true)
        XCTAssertEqual(
            ConnectionDiagnostics.sessionBlock(expired),
            "VPN session expired. Sign in again."
        )
        XCTAssertNil(ConnectionDiagnostics.sessionBlock(VPNSession(present: true, expiresAt: nil, loginRequired: false)))
    }

    @MainActor
    func testExpiredSessionAsksForASignInEvenWithNoAccountMismatch() throws {
        // The gap: `vpnSignInRequired` was set ONLY by the account-follow path, so a plain expiry
        // showed no message and no Sign In button. The menu bar tinted and said nothing.
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":false,"loginRequired":true},"clusters":[{"cid":"c1","name":"One","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#.utf8)
        let store = StateStore()
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)
        store.vpnSignInRequired = false

        XCTAssertTrue(store.signInRequired)
        XCTAssertEqual(store.menuBarState, .attention)
    }

    @MainActor
    func testAWorkingSessionAsksForNothing() throws {
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"c1","name":"One","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#.utf8)
        let store = StateStore()
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)

        XCTAssertFalse(store.signInRequired)
        XCTAssertEqual(store.menuBarState, .connected)
    }
}

/*
 Knowing WHEN the session ends, so a 24-hour expiry is a thing you can plan around rather than a
 morning of failed pings. Asked for after the 2026-08-25 expiry: the app said nothing until
 everything was already broken.
*/
extension ModelTests {
    private static let utc = TimeZone(identifier: "UTC")!

    private func expiry(_ isoExpiry: String, now isoNow: String) -> String? {
        let session = VPNSession(
            present: true,
            expiresAt: ISO8601DateFormatter().date(from: isoExpiry),
            loginRequired: false
        )
        return MenuPresentation.sessionExpiry(
            session,
            now: ISO8601DateFormatter().date(from: isoNow)!,
            timeZone: Self.utc
        )
    }

    func testSessionExpiryStatesBothHowLongAndWhen() {
        // Both halves earn their place: "in 21h" is what you plan around, "09:59" is what you
        // recognise tomorrow morning when it has already happened.
        XCTAssertEqual(
            expiry("2026-08-26T09:59:00Z", now: "2026-08-25T12:30:00Z"),
            "Session expires in 21h (09:59)"
        )
    }

    func testSessionExpiryDropsToMinutesInsideTheLastHour() {
        XCTAssertEqual(
            expiry("2026-08-25T13:13:00Z", now: "2026-08-25T12:30:00Z"),
            "Session expires in 43m (13:13)"
        )
        XCTAssertEqual(
            expiry("2026-08-25T12:30:20Z", now: "2026-08-25T12:30:00Z"),
            "Session expires in under a minute (12:30)"
        )
    }

    func testSessionExpiryRoundsHoursDownSoItNeverOverstates() {
        // 21h59m must read "in 21h", never "in 22h". Rounding up would tell someone they have
        // longer than they do, which is the one direction this must not err in.
        XCTAssertEqual(
            expiry("2026-08-26T10:29:00Z", now: "2026-08-25T12:30:00Z"),
            "Session expires in 21h (10:29)"
        )
    }

    func testNoExpiryLineWhenThereIsNothingTrueToSay() {
        // Already expired: the Sign In prompt owns that state, and a second line saying "expires in
        // 0m" would compete with it.
        XCTAssertNil(expiry("2026-08-25T09:59:00Z", now: "2026-08-25T12:30:00Z"))
        // No session at all, and a session whose end the CLI did not report.
        XCTAssertNil(MenuPresentation.sessionExpiry(
            VPNSession(present: false, expiresAt: nil, loginRequired: true),
            now: Date(),
            timeZone: Self.utc
        ))
        XCTAssertNil(MenuPresentation.sessionExpiry(
            VPNSession(present: true, expiresAt: nil, loginRequired: false),
            now: Date(),
            timeZone: Self.utc
        ))
    }

    @MainActor
    func testTheLastHourIsWorthSayingOutLoud() throws {
        // In the VPN submenu it is reference. In the last hour it is something to act on, so it
        // moves to the top-level status where it cannot be missed.
        let store = StateStore()
        XCTAssertFalse(store.sessionEndingSoon(now: Date()))

        let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(40 * 60))
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false,"expiresAt":"__WHEN__"},"clusters":[]}"#
            .replacingOccurrences(of: "__WHEN__", with: soon).utf8)
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)
        XCTAssertTrue(store.sessionEndingSoon(now: Date()))

        let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 3600))
        let far = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false,"expiresAt":"__WHEN__"},"clusters":[]}"#
            .replacingOccurrences(of: "__WHEN__", with: later).utf8)
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: far)
        XCTAssertFalse(store.sessionEndingSoon(now: Date()))
    }
}

/*
 Reported 2026-08-25, from the menu with an expired session open: "i am currently signed out, but
 the checkmark is still there and there is a sign out".

 The VPN submenu was gated on `vpn.running`, which is only the tunnel INTERFACE. An expired session
 leaves that interface up, so the submenu drew every cluster as a ticked toggle and offered to sign
 out of a session that had already ended. The tick is the worse half: it is the app asserting a
 cluster is connected and carrying traffic while nothing routes.
*/
extension ModelTests {
    @MainActor
    private func store(session: String, clusterConnected: Bool = true) throws -> StateStore {
        let data = Data((#"{"schemaVersion":1,"running":true,"session":"#
            + session
            + #","clusters":[{"cid":"c1","name":"One","connected":"#
            + (clusterConnected ? "true" : "false")
            + #","reachable":true,"peerUp":true,"peeredWith":[]}]}"#).utf8)
        let store = StateStore()
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)
        return store
    }

    @MainActor
    func testVPNControlsAreUnusableWhileASignInIsOwed() throws {
        // The tunnel is up and the cluster still reads connected: that is exactly the state that
        // drew a tick over a dead path. The controls must not be reachable to assert it.
        let expired = try store(session: #"{"present":false,"loginRequired":true}"#)
        XCTAssertFalse(expired.vpnControlsUsable)
        XCTAssertTrue(expired.signInRequired)
    }

    @MainActor
    func testVPNControlsWorkWithALiveSession() throws {
        let live = try store(session: #"{"present":true,"loginRequired":false}"#)
        XCTAssertTrue(live.vpnControlsUsable)
        XCTAssertFalse(live.signInRequired)
    }

    @MainActor
    func testAnAccountSwitchAlsoLocksTheVPNControls() throws {
        // The other cause of `signInRequired`. One rule covers both: until the sign-in happens,
        // nothing in that submenu can do what its label says.
        let store = try store(session: #"{"present":true,"loginRequired":false}"#)
        store.vpnSignInRequired = true
        XCTAssertFalse(store.vpnControlsUsable)
    }
}

/*
 Reported 2026-08-25: "it still says sign out, even if it is grayed, it still bothers me, it should
 say signed out".

 Greying the submenu stopped it being CLICKED and changed nothing about what it CLAIMED. It still
 ticked a cluster as connected and still labelled a control "Sign Out" for a session that had
 already ended. A disabled control is still a sentence, and that sentence was wrong.

 The submenu has three modes, and which one it is in is decided by the SESSION first, never by the
 tunnel interface.
*/
extension ModelTests {
    @MainActor
    private func mode(session: String, running: Bool, mismatch: Bool = false) throws -> VPNMenuMode {
        let data = Data((#"{"schemaVersion":1,"running":"#
            + (running ? "true" : "false")
            + #","session":"# + session
            + #","clusters":[{"cid":"c1","name":"One","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#).utf8)
        let store = StateStore()
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)
        store.vpnSignInRequired = mismatch
        return store.vpnMenuMode
    }

    @MainActor
    func testAnExpiredSessionIsSignedOutEvenWhileTheTunnelIsUp() throws {
        // The reported defect. `running` is the tunnel INTERFACE and it stays up through an expiry,
        // so deciding on it drew ticks and a Sign Out over a session that had ended.
        XCTAssertEqual(
            try mode(session: #"{"present":false,"loginRequired":true}"#, running: true),
            .signedOut
        )
    }

    @MainActor
    func testALiveSessionOnAnUpTunnelShowsTheClusters() throws {
        XCTAssertEqual(
            try mode(session: #"{"present":true,"loginRequired":false}"#, running: true),
            .connected
        )
    }

    @MainActor
    func testALiveSessionOnADownTunnelOffersToConnect() throws {
        XCTAssertEqual(
            try mode(session: #"{"present":true,"loginRequired":false}"#, running: false),
            .disconnected
        )
    }

    @MainActor
    func testAnAccountSwitchIsAlsoSignedOut() throws {
        XCTAssertEqual(
            try mode(session: #"{"present":true,"loginRequired":false}"#, running: true, mismatch: true),
            .signedOut
        )
    }

    @MainActor
    func testNoVPNStatusAtAllIsNotSignedOut() throws {
        // Nothing known yet, at first launch. Claiming "signed out" would be inventing a fact.
        let store = StateStore()
        XCTAssertEqual(store.vpnMenuMode, .disconnected)
    }
}

/*
 The sign-in window reads `runos login --json` / `runos vpn up --json` as a stream of events. The
 two facts it exists to show: the DEVICE ID, which the person compares against the browser page (a
 code that does not match means the page is not the one the CLI opened), and the URL, which is the
 only way in when the browser does not open.
*/
extension ModelTests {
    func testDeviceCodeCarriesTheIDAndTheURL() {
        // It arrives BEFORE anything about a browser, so the window can show the code to compare
        // against before a browser takes focus.
        let line = #"{"event":"device_code","deviceId":"a1b2c3","url":"https://console.example/account/connect-device/a1b2c3-tok"}"#
        XCTAssertEqual(
            SignInEvent.parse(line),
            .deviceCode(id: "a1b2c3", url: "https://console.example/account/connect-device/a1b2c3-tok")
        )
    }

    func testWhetherABrowserOpenedIsItsOwnEvent() {
        // It can only be known after the attempt, which is after the code is on screen.
        XCTAssertEqual(SignInEvent.parse(#"{"event":"browser_opened","browserOpened":true}"#), .browserOpened(true))
        // Absent reads as "did not open", the safe way round: the window shows the URL prominently
        // rather than assuming a browser the person cannot see.
        XCTAssertEqual(SignInEvent.parse(#"{"event":"browser_opened"}"#), .browserOpened(false))
    }

    func testTheOtherEvents() {
        XCTAssertEqual(SignInEvent.parse(#"{"event":"pending"}"#), .pending)
        XCTAssertEqual(SignInEvent.parse(#"{"event":"authorized"}"#), .authorized)
        XCTAssertEqual(
            SignInEvent.parse(#"{"event":"error","reason":"expired","message":"authorization expired"}"#),
            .failed(reason: "expired", message: "authorization expired")
        )
    }

    func testAnErrorAlwaysHasSomethingToSayEvenIfTheCLISaidLittle() {
        guard case .failed(let reason, let message)? = SignInEvent.parse(#"{"event":"error"}"#) else {
            return XCTFail("an error event must still parse")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertFalse(message.isEmpty)
    }

    func testUnknownAndMalformedLinesAreIGNORED() {
        // The CLI may add an event this build has never heard of, and a sign-in must not break
        // because of one. Nor may a stray log line or a blank line end the flow.
        XCTAssertNil(SignInEvent.parse(#"{"event":"something_new","x":1}"#))
        XCTAssertNil(SignInEvent.parse("not json at all"))
        XCTAssertNil(SignInEvent.parse(""))
        XCTAssertNil(SignInEvent.parse("   "))
        // A device_code missing the very fields it exists for is not usable as one.
        XCTAssertNil(SignInEvent.parse(#"{"event":"device_code","url":"https://x"}"#))
        XCTAssertNil(SignInEvent.parse(#"{"event":"device_code","deviceId":"a1b2c3"}"#))
        XCTAssertNil(SignInEvent.parse(#"{"event":"device_code","deviceId":"","url":"https://x"}"#))
    }
}

/*
 A pipe delivers whatever chunks it feels like, which is not lines. The device_code event is the
 longest line in the sign-in stream and therefore the likeliest to be split across two reads, and it
 is the one carrying the two facts the window exists to show.
*/
extension ModelTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        var collected: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    private func collect(_ chunks: [String], finish: Bool = true) -> [String] {
        let sink = Sink()
        let buffer = LineBuffer { line in sink.append(line) }
        chunks.forEach { buffer.append(Data($0.utf8)) }
        if finish { buffer.finish() }
        return sink.collected
    }

    func testALineSplitAcrossTwoReadsArrivesWhole() {
        XCTAssertEqual(
            collect([#"{"event":"device_"#, #"code","deviceId":"a1b2c3"}"# + "\n"]),
            [#"{"event":"device_code","deviceId":"a1b2c3"}"#]
        )
    }

    func testSeveralLinesInOneReadAllArrive() {
        XCTAssertEqual(
            collect(["{\"event\":\"pending\"}\n{\"event\":\"pending\"}\n{\"event\":\"authorized\"}\n"]),
            ["{\"event\":\"pending\"}", "{\"event\":\"pending\"}", "{\"event\":\"authorized\"}"]
        )
    }

    func testAPartialLineIsHeldUntilItsNewlineArrives() {
        // Delivering it early would hand the parser a fragment, and the parser would correctly
        // ignore it, losing the event entirely.
        XCTAssertEqual(collect([#"{"event":"pen"#], finish: false), [])
    }

    func testTheLastLineArrivesEvenWithoutATrailingNewline() {
        XCTAssertEqual(collect([#"{"event":"authorized"}"#]), [#"{"event":"authorized"}"#])
        XCTAssertEqual(collect([""]), [])
    }
}

/*
 Reported 2026-08-25, with a screenshot of the menu: "lol what is this long message? The top should
 just say You are currently signed out".

 Conductor's sentence, "Your session is 28 hours old and sessions expire after 24. Run `runos login`
 to sign in again.", was landing in the menu verbatim. It is written for a terminal, where `runos
 login` is a thing you type; in a dropdown with a Sign In button two lines above it, it is a
 paragraph explaining a state the app already has a control for.

 Being signed out is a STATE, not an error. The app branches on the flag, never on the sentence.
*/
extension ModelTests {
    @MainActor
    private func signedOutStore() throws -> StateStore {
        let data = Data(#"{"schemaVersion":1,"authenticated":false,"accountId":"acct","sessionExpired":true,"authError":"Your session is 28 hours old and sessions expire after 24. Run `runos login` to sign in again."}"#.utf8)
        let store = StateStore()
        store.cliStatus = try JSONDecoder.runOS.decode(CLIStatus.self, from: data)
        return store
    }

    @MainActor
    func testAnExpiredSessionAsksForASignInWithoutTheParagraph() throws {
        let store = try signedOutStore()
        XCTAssertTrue(store.signInRequired)
        // The sentence must not become the error banner. It is not an error; it is the state the
        // Sign In button exists for.
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testAnExpiredSessionShowsTHEBUTTONANDNOTHINGELSE() throws {
        // "You are currently signed out." over a button reading "Sign In" says the same thing
        // twice, the first time in greyed-out text that cannot be acted on. The button is the
        // statement. `cliSessionExpired` is what the menu keys the line off, so it must be true
        // here and the sentence must never be built.
        let store = try signedOutStore()
        XCTAssertTrue(store.cliSessionExpired)
        XCTAssertTrue(store.signInRequired)
    }

    func testAnAccountMismatchKeepsItsOwnSentence() throws {
        // A different situation with a different thing to say: the VPN belongs to another account.
        // Collapsing both into "signed out" would lose the part that matters.
        XCTAssertTrue(MenuPresentation.signInPrompt(account: "acct").contains("acct"))
    }

    @MainActor
    func testARealErrorStillReachesTheMenu() throws {
        // The rule is narrow: only the session-expiry sentence is suppressed, because only that one
        // has a control beside it. Anything else the CLI says still surfaces.
        let store = StateStore()
        store.errorMessage = "the daemon is not running"
        XCTAssertEqual(store.errorMessage, "the daemon is not running")
    }
}

/*
 Reported 2026-08-25: "the runos vpn icon is fully lit even though I am disconnected, it should be
 grayed out like I am not connected to anything".

 `imageName` greyed out for `.off` alone, so `.attention` reused the LIT icon and was
 indistinguishable from `.connected`. Signed out, tunnel down, nothing routing: the menu bar still
 said the VPN was carrying traffic.

 The lit icon means ONE thing: the VPN is carrying something. `menuBarState` already holds that line
 for `.connected`, which demands a cluster connected AND reachable. The icon has to hold it too.
*/
extension ModelTests {
    func testOnlyAWorkingConnectionLightsTheIcon() {
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: .connected, isActive: false, reduceMotion: false, frame: 0),
            "MenuBarIcon"
        )
        // Everything else is "not carrying anything", and must look it.
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: .attention, isActive: false, reduceMotion: false, frame: 0),
            "MenuBarIconOff"
        )
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: .off, isActive: false, reduceMotion: false, frame: 0),
            "MenuBarIconOff"
        )
    }

    func testAnOperationInFlightStillAnimates() {
        // `isActive` is about work happening right now and is a different axis from whether the
        // tunnel carries traffic. Greying `.attention` must not silence the activity animation.
        let frames = (0..<3).map {
            MenuBarIconAnimation.imageName(state: .attention, isActive: true, reduceMotion: false, frame: $0)
        }
        XCTAssertEqual(frames, ["MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3"])
    }

    @MainActor
    func testBeingSignedOutDoesNotLightTheIcon() throws {
        let data = Data(#"{"schemaVersion":1,"authenticated":false,"accountId":"acct","sessionExpired":true}"#.utf8)
        let store = StateStore()
        store.cliStatus = try JSONDecoder.runOS.decode(CLIStatus.self, from: data)
        XCTAssertEqual(store.menuBarState, .attention)
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(state: store.menuBarState, isActive: false, reduceMotion: false, frame: 0),
            "MenuBarIconOff"
        )
    }
}

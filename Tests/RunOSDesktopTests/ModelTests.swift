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
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"g4v","name":"vhm-lab","connected":true,"reachable":false,"reason":"no VPN server installed","peerUp":false,"peeredWith":[]}] }"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)

        XCTAssertFalse(result.hasWorkingConnection, "a cluster with no VPN server is not a working connection")
        XCTAssertTrue(result.clusters[0].isDeadConnection)

        // The label a person reads must carry the trouble, not just the name.
        let label = MenuPresentation.clusterLabel(result.clusters[0])
        XCTAssertTrue(label.contains("vhm-lab"), "keeps the name, got \(label)")
        XCTAssertTrue(label.contains("no VPN server installed"), "must say why it is not working, got \(label)")
    }

    func testAWorkingConnectionIsLabelledPlainly() throws {
        let data = Data(#"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"g4v","name":"vhm-lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}] }"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)

        XCTAssertTrue(result.hasWorkingConnection)
        XCTAssertFalse(result.clusters[0].isDeadConnection)
        XCTAssertEqual(MenuPresentation.clusterLabel(result.clusters[0]), "vhm-lab (g4v)")
    }

    /*
     The only thing an account difference may ever put in front of a person.

     The app follows the account you are signed in to by itself. When Conductor wants a fresh
     sign-in it cannot, and then this is said: a thing to do, naming the account it is for, and
     never the two-account state behind it.
    */
    func testSignInPromptAsksForTheOneThingAPersonCanDo() {
        let prompt = MenuPresentation.signInPrompt(account: "rjwrn")

        XCTAssertTrue(prompt.contains("rjwrn"), "names the account it is for, got \(prompt)")
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
        store.vpnStatus = try? JSONDecoder.runOS.decode(VPNStatus.self, from: Data(#"{"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"g4v","name":"lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#.utf8))
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

        store.vpnStatus = try? JSONDecoder.runOS.decode(VPNStatus.self, from: Data(#"{"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"g4v","name":"lab","connected":true,"reachable":false,"reason":"no VPN server installed","peerUp":false,"peeredWith":[]}]}"#.utf8))
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
        XCTAssertEqual(MenuPresentation.clusterLabel(name: "vhm-lab", cid: "g4v"), "vhm-lab (g4v)")
        XCTAssertEqual(MenuPresentation.clusterLabel(name: "", cid: "g4v"), "g4v")
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
            vpn: nil
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
        {"schemaVersion":2,"running":true,"interface":"utun0","address":"10.153.46.3/32",
         "session":{"present":true,"loginRequired":false},
         "dns":{"available":true,"mode":"native","error":""},
         "clusters":[{"cid":"v6b","name":"host-homelab","connected":true,"reachable":true,
           "endpoint":"192.168.0.226:32768","resolver":"10.58.72.2","peerUp":true,"peeredWith":[],
           "rxBytes":12345,"txBytes":67890,"lastHandshake":"2026-08-24T11:44:22+02:00"}]}
        """.data(using: .utf8)!
        let status = try JSONDecoder.runOS.decode(VPNStatus.self, from: json)
        XCTAssertEqual(status.interface, "utun0")
        XCTAssertEqual(status.dns?.mode, "native")
        XCTAssertEqual(status.clusters[0].endpoint, "192.168.0.226:32768")
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

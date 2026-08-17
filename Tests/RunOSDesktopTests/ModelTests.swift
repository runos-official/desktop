import Combine
import AppKit
import XCTest
@testable import RunOSDesktop

final class ModelTests: XCTestCase {
    func testAccountListDecoder() throws {
        let data = Data(#"{"schemaVersion":1,"accounts":[{"accountId":"acct","active":true,"addedAt":"2026-08-01T00:00:00Z","lastUsedAt":"2026-08-02T00:00:00Z","vpnIdentityPresent":true,"vpnSessionPresent":false}]}"#.utf8)
        let result = try JSONDecoder.runOS.decode(AccountListResult.self, from: data)
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.accounts.first?.accountId, "acct")
        XCTAssertTrue(result.accounts.first?.active == true)
    }

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

        XCTAssertEqual(result.connectableClusters.map(\.cid), ["ready", "active"])
        XCTAssertEqual(result.connectableClusters.filter(\.connected).map(\.cid), ["active"])
    }

    @MainActor
    func testMenuBarStateDerivation() {
        let store = StateStore()
        XCTAssertEqual(store.menuBarState, .off)
        store.errorMessage = "problem"
        XCTAssertEqual(store.menuBarState, .attention)
        store.errorMessage = nil
        store.vpnStatus = try? JSONDecoder.runOS.decode(VPNStatus.self, from: Data(#"{"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#.utf8))
        XCTAssertEqual(store.menuBarState, .connected)
    }

    @MainActor
    func testUpdateActionShowsProgressWhileUpdateRuns() {
        let store = StateStore()
        XCTAssertEqual(store.updateActionTitle, "Update RunOS")

        store.operationMessage = "Updating RunOS…"

        XCTAssertEqual(store.updateActionTitle, "Updating RunOS…")
    }

    func testCommandConstruction() {
        XCTAssertEqual(DesktopCommands.switchAccount("acct"), ["account", "switch", "acct", "--json"])
        XCTAssertEqual(DesktopCommands.setVPN(enabled: false), ["vpn", "down", "--json"])
        XCTAssertEqual(DesktopCommands.setCluster("cid", connected: false), ["vpn", "connect", "cid", "--json"])
        XCTAssertEqual(
            DesktopCommands.toggleCluster("cid", isConnected: true, connectedClusterCount: 1),
            ["vpn", "down", "--json"]
        )
        XCTAssertEqual(
            DesktopCommands.toggleCluster("cid", isConnected: true, connectedClusterCount: 2),
            ["vpn", "disconnect", "cid", "--json"]
        )
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
            MenuBarIconAnimation.imageName(isActive: false, reduceMotion: false, frame: 2),
            "MenuBarIcon"
        )
        XCTAssertEqual(
            (0..<4).map { MenuBarIconAnimation.imageName(isActive: true, reduceMotion: false, frame: $0) },
            ["MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3", "MenuBarActivity1"]
        )
        XCTAssertEqual(
            MenuBarIconAnimation.imageName(isActive: true, reduceMotion: true, frame: 2),
            "MenuBarIcon"
        )
    }

    @MainActor
    func testMenuBarActivityIconsHaveRetinaResolution() throws {
        for name in ["MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3"] {
            let icon = try XCTUnwrap(NSImage(named: name))
            let largestWidth = icon.representations.map(\.pixelsWide).max()

            XCTAssertGreaterThanOrEqual(largestWidth ?? 0, 36)
        }
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
            companyName: "Example Company"
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
}

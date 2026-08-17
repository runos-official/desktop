import Combine
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

    func testVPNStatusDecoderKeepsUnreachableReasonAndPeering() throws {
        let data = Data(#"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[{"cid":"c1","name":"One","connected":true,"reachable":false,"reason":"no server","peerUp":false,"peeredWith":["c2"]}]}"#.utf8)
        let result = try JSONDecoder.runOS.decode(VPNStatus.self, from: data)
        XCTAssertEqual(result.clusters.first?.reason, "no server")
        XCTAssertEqual(result.clusters.first?.peeredWith, ["c2"])
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

    func testCommandConstruction() {
        XCTAssertEqual(DesktopCommands.switchAccount("acct"), ["account", "switch", "acct", "--json"])
        XCTAssertEqual(DesktopCommands.setVPN(enabled: false), ["vpn", "down", "--json"])
        XCTAssertEqual(DesktopCommands.setCluster("cid", connected: false), ["vpn", "connect", "cid", "--json"])
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

    @MainActor
    func testAboutPresenterOpensPanel() {
        var presentationCount = 0
        let presenter = AboutPresenter {
            presentationCount += 1
        }

        presenter.show()

        XCTAssertEqual(presentationCount, 1)
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

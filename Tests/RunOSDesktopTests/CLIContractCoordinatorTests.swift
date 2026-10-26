import XCTest
@testable import RunOSDesktop

/*
 The golden outputs, served by a fake CLI to the real coordinator.

 CLIContractFixtureTests checks that each file decodes or fails clearly. This checks what a person
 would SEE: after one refresh against each file, the menu either shows the state the file describes
 or says plainly that it cannot read it. It is never the bare menu of FCR 1730, where the status
 was dropped and nothing said so.
*/
@MainActor
final class CLIContractCoordinatorTests: XCTestCase {

    private func layout(_ store: StateStore) -> MenuLayout {
        MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false, loginItemError: nil, now: Date())
    }

    func testEveryVPNStatusFixtureEitherShowsAStateOrSaysItCannotRead() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try cli.runner(), autoConnect: makeAutoConnect())
        var shown = 0, refused = 0
        for stem in try Fixtures.stems(in: "vpn-status") {
            try cli.setFixture("vpn status --json", family: "vpn-status", stem: stem)
            await coordinator.refresh()
            let menu = layout(store)
            if store.vpnStatus != nil {
                shown += 1
                XCTAssertNil(store.vpnStatusProblem, stem)
                XCTAssertNil(menu.item("status.vpn-problem"), stem)
            } else {
                refused += 1
                guard case .unreadable(let failure) = store.vpnStatusProblem else {
                    XCTFail("\(stem): no status and no stated problem"); continue
                }
                XCTAssertEqual(menu.item("status.vpn-problem")?.title, failure.headline, stem)
                XCTAssertFalse(menu.item("status.vpn-problem-reason")?.title.isEmpty ?? true, stem)
            }
            // Whatever the answer, Restart VPN is there to be pressed.
            XCTAssertEqual(menu.item("restart-vpn")?.enabled, true, stem)
            XCTAssertNotNil(menu.item("vpn"), stem)
        }
        XCTAssertGreaterThan(shown, 20)
        XCTAssertGreaterThan(refused, 8)
    }

    func testEveryStatusFixtureEitherSignsTheStateOrSaysItCannotRead() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try cli.runner(), autoConnect: makeAutoConnect())
        for stem in try Fixtures.stems(in: "status") {
            store.cliStatus = nil
            store.errorMessage = nil
            try cli.setFixture("status --json", family: "status", stem: stem)
            await coordinator.refresh()
            if store.cliStatus == nil {
                XCTAssertTrue(store.errorMessage?.hasPrefix("Cannot read the RunOS status") == true,
                              "\(stem): \(String(describing: store.errorMessage))")
                XCTAssertNotNil(layout(store).item("status.error"), stem)
            } else if let status = store.cliStatus, !status.authenticated {
                XCTAssertNotNil(layout(store).item("signin") ?? layout(store).item("status.error"), "\(stem): signed out and nothing to do")
            }
        }
    }

    func testEveryUpdateCheckFixtureLeavesUpdateUsable() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        for stem in try Fixtures.stems(in: "update-check") {
            let store = StateStore()
            let coordinator = RefreshCoordinator(store: store, runner: try cli.runner(), autoConnect: makeAutoConnect())
            try cli.setFixture("update --check --json", family: "update-check", stem: stem)
            await coordinator.refresh()
            XCTAssertNotNil(store.updateVerdictKnown, "\(stem): asked, so the answer is known or known to be unknown")
            XCTAssertNil(store.errorMessage, "\(stem): the update check never raises a banner")
            // Disabled only when it positively said there is nothing to install.
            if !store.updateActionEnabled {
                XCTAssertEqual(store.updateVerdictKnown, true, stem)
                XCTAssertFalse(store.updateAvailable, stem)
            }
        }
    }

    func testPendingDNSFixtureReachesTheMenuAsOneCalmLine() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        try cli.setFixture("vpn status --json", family: "vpn-status", stem: "pending-dns")
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try cli.runner(), autoConnect: makeAutoConnect())
        await coordinator.refresh()
        guard let vpn = store.vpnStatus else { return XCTFail("did not decode") }
        XCTAssertEqual(vpn.dns?.pending, true)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.vpnStatusProblem)
    }
}

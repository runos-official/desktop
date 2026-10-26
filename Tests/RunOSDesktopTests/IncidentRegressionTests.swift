import XCTest
@testable import RunOSDesktop

/*
 One test per thing that went wrong, named for it. Each is a small, direct statement of the
 incident; the wider tests (the state matrix, the contract fixtures, the scenarios) hold the same
 ground more broadly. If one of these fails, the incident is back.
*/
@MainActor
final class IncidentRegressionTests: XCTestCase {

    private func layout(_ store: StateStore) -> MenuLayout {
        MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false, loginItemError: nil, now: Date())
    }

    private func signedOut(_ store: StateStore) {
        store.cliStatus = CLIStatus(
            schemaVersion: 1, authenticated: false, accountId: nil, companyName: nil, vpnAccountId: nil,
            vpnAccountMismatch: nil, vpnRunning: nil, authError: nil, sessionExpired: nil, authErrorKind: "rejected")
    }

    // MARK: FCR 1726, "Finishing sign in…" twice

    func testFCR1726_FinishingSignInIsInTheMenuExactlyOnce() {
        let store = StateStore()
        signedOut(store)
        store.operationMessage = SignInPurpose.signIn.finishingMessage
        let texts = layout(store).items.compactMap(\.shownText)
        XCTAssertEqual(texts.filter { $0 == "Finishing sign in…" }.count, 1)
    }

    func testFCR1726_NoTextRepeatsInAnyBusyStateWhileSignedOut() {
        for busy in MenuStateMatrixTests.Busy.allCases {
            let store = StateStore()
            signedOut(store)
            store.operationMessage = MenuStateMatrixTests.operationMessage(busy)
            store.isUpdating = busy == .update
            let texts = layout(store).items.compactMap(\.shownText)
            XCTAssertEqual(texts.count, Set(texts).count, "\(busy): \(texts)")
        }
    }

    // MARK: FCR 1730, a null list blanked the menu

    func testFCR1730_ClustersNullKeepsTheClusterRowsAndTheMenu() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        try cli.setFixture("vpn status --json", family: "vpn-status", stem: "hostile-null-clusters")
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try cli.runner(), autoConnect: makeAutoConnect())

        await coordinator.refresh()

        XCTAssertNotNil(store.vpnStatus, "a null clusters list is an empty one, not a failed status")
        XCTAssertNil(store.vpnStatusProblem)
        XCTAssertEqual(store.vpnStatus?.clusters.count, 0)
    }

    // MARK: FCR 1730, a status nobody could read gave a bare menu with no error

    func testFCR1730_AnUnreadableVPNStatusIsNeverABareMenu() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn status --json", out: "<html>502 Bad Gateway</html>")
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try cli.runner(), autoConnect: makeAutoConnect())

        await coordinator.refresh()

        let menu = layout(store)
        XCTAssertEqual(menu.item("status.vpn-problem")?.title, "Cannot read the VPN status")
        XCTAssertTrue(menu.item("status.vpn-problem-reason")?.title.contains("text instead of JSON") == true,
                      menu.item("status.vpn-problem-reason")?.title ?? "none")
    }

    // MARK: FCR 1730, Restart VPN was invisible exactly when needed

    func testFCR1730_RestartVPNIsOfferedWhenTheStatusCannotBeRead() {
        let store = StateStore()
        store.cliVersion = "1.22.2"
        store.vpnStatus = nil
        store.vpnStatusProblem = .unreadable(ReadFailure(headline: "Cannot read the VPN status", reason: "the output ends too early; it looks cut off."))
        XCTAssertEqual(layout(store).item("restart-vpn")?.enabled, true)
    }

    func testFCR1730_RestartVPNIsOfferedWithNoDriftAtAll() {
        let store = StateStore()
        store.cliVersion = "1.22.2"
        XCTAssertFalse(store.vpnRestartRequired)
        XCTAssertEqual(layout(store).item("restart-vpn")?.title, "Restart VPN")
        XCTAssertEqual(layout(store).item("restart-vpn")?.enabled, true)
    }

    func testFCR1730_RestartVPNIsDisabledOnlyWhileAnotherActionRuns() {
        let store = StateStore()
        store.operationMessage = "Disconnecting VPN…"
        let item = layout(store).item("restart-vpn")
        XCTAssertEqual(item?.enabled, false)
        XCTAssertEqual(item?.disabledReason, .operationRunning)
        XCTAssertNotNil(layout(store).items.first { $0.title == "Disconnecting VPN…" }, "the reason is in view")
    }

    // MARK: FCR 1730, the long error was cut where the remedy started

    func testFCR1730_ALongErrorIsAMenuSummaryPlusTheWholeInDetails() {
        let sentence = "Error: private DNS zone example.test could not be applied. This is usually timing rather than a broken cluster. Run `runos vpn connect c-example1` again in a few seconds."
        let store = StateStore()
        store.errorMessage = sentence
        let menu = layout(store)
        XCTAssertLessThanOrEqual(menu.item("status.error")?.title.count ?? 999, ErrorPresentation.menuLineLimit)
        XCTAssertEqual(menu.details, sentence)
        XCTAssertEqual(menu.items.first { $0.action == .showDetails }?.title, "Show Details…")
    }

    // MARK: FCR 1730, the first Connect hit a DNS error; the CLI now says "pending"

    func testFCR1730_PendingDNSDecodesAndIsNotAnError() throws {
        let data = try Fixtures.data("vpn-status", "pending-dns")
        let vpn = try CLIReading.decode(VPNStatus.self, from: data, what: "the VPN status").get()
        XCTAssertEqual(vpn.dns?.pending, true)
        let store = StateStore()
        store.vpnStatus = VPNStatus(
            schemaVersion: 1, running: true, accountId: nil,
            session: VPNSession(present: true, expiresAt: Date().addingTimeInterval(7200), loginRequired: false),
            clusters: MenuStateMatrixTests.clusters(.one), lastPollError: nil, interface: nil, address: nil,
            dns: vpn.dns, version: nil)
        XCTAssertTrue(store.dnsPending)
        XCTAssertNil(store.dnsFailure)
        XCTAssertEqual(store.menuBarState, .connected)
    }

    func testFCR1730_AReleasedCLIWithoutThePendingFieldStillDecodes() throws {
        let data = try Fixtures.data("vpn-status", "released-cli-without-dns-pending")
        let vpn = try CLIReading.decode(VPNStatus.self, from: data, what: "the VPN status").get()
        XCTAssertNil(vpn.dns?.pending)
    }

    // MARK: FCR 1732, a permission error offered Install

    func testFCR1732_ASocketPermissionErrorIsNotAMissingService() throws {
        let text = try Fixtures.text("cli-errors", "permission-denied-service-running")
        XCTAssertFalse(VPNService.isMissing(CLIExecutionError(exitCode: 1, message: text)))
    }

    // MARK: FCR 1733, two icons

    func testFCR1733_ASecondCopyQuitsAfterTheWaitAndAFirstCopyNeverWaits() {
        XCTAssertEqual(SingleInstance.decision(otherCopies: 1, waited: 5, maxWait: 5), .quit)
        XCTAssertEqual(SingleInstance.decision(otherCopies: 0, waited: 0, maxWait: 5), .proceed)
    }
}

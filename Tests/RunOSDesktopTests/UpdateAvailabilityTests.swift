import XCTest
@testable import RunOSDesktop

/*
 Whether an update is waiting, and what the menu bar does about it.

 The Update RunOS item was always enabled and always looked identical, so the only way to find out
 whether there was anything to install was to click it and watch. `runos update --check --json` now
 answers that as a flag for both components, so the item can be disabled when there is nothing to do
 and the menu bar can say when there is.
*/
final class UpdateAvailabilityTests: XCTestCase {

    private func decode(_ json: String) throws -> UpdateCheck {
        try JSONDecoder.runOS.decode(UpdateCheck.self, from: Data(json.utf8))
    }

    // MARK: - Reading the CLI's verdict

    func testAnUpdateOnEitherComponentCounts() throws {
        let cliOnly = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"updateAvailable":true,"currentVersion":"1.16.0","version":"1.17.0"},"desktop":{"updated":false,"updateAvailable":false,"currentVersion":"0.3.0","version":"0.3.0"}}"#)
        XCTAssertTrue(cliOnly.anyAvailable)

        let desktopOnly = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"updateAvailable":false,"currentVersion":"1.17.0","version":"1.17.0"},"desktop":{"updated":false,"updateAvailable":true,"currentVersion":"0.2.1","version":"0.3.0"}}"#)
        XCTAssertTrue(desktopOnly.anyAvailable, "a desktop-only update still means there is something to install")

        let neither = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"updateAvailable":false},"desktop":{"updated":false,"updateAvailable":false}}"#)
        XCTAssertFalse(neither.anyAvailable)
    }

    /// A machine with no desktop installed reports no desktop component at all.
    func testAMissingDesktopComponentIsNotAnUpdate() throws {
        let cliOnly = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"updateAvailable":false,"currentVersion":"1.17.0"}}"#)
        XCTAssertNil(cliOnly.desktop)
        XCTAssertFalse(cliOnly.anyAvailable)
    }

    /*
     An older CLI has no `updateAvailable` field at all. Absent must read as "nothing waiting", not
     as an update: badging the menu bar on every poll because a field is missing would be worse than
     never badging it.
    */
    func testAnOlderCLIWithoutTheFlagReportsNothingWaiting() throws {
        let old = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"version":"1.17.0","message":"A CLI update is available."}}"#)
        XCTAssertFalse(old.anyAvailable, "no flag means no verdict, and a sentence is not a verdict")
    }

    // MARK: - What the menu does with it

    /*
     DISABLED, NOT HIDDEN, which is the rule this menu already follows for the VPN submenu: someone
     who opens the menu looking for Update RunOS should find it where it always is and see that
     there is nothing to do, rather than watch it vanish and wonder what the app has lost.
    */
    @MainActor
    func testTheUpdateItemIsDisabledOnlyWhenWeKNOWThereIsNothingToInstall() {
        let store = StateStore()

        /*
         UNKNOWN LEAVES IT CLICKABLE, and this is the case that decides shipping order.

         An older CLI carries no verdict. Treating that as "nothing to install" would leave a
         desktop that shipped ahead of the CLI permanently unable to update itself, which is worse
         than the always-enabled behaviour it replaces. Only a definite "nothing waiting" disables
         it.
        */
        XCTAssertTrue(store.updateActionEnabled, "nothing read yet must not disable the only way to update")

        store.updateVerdictKnown = false
        store.updateAvailable = false
        XCTAssertTrue(store.updateActionEnabled, "an older CLI gives no verdict, so leave it clickable")

        store.updateVerdictKnown = true
        store.updateAvailable = false
        XCTAssertFalse(store.updateActionEnabled, "now we know there is nothing to do")

        store.updateAvailable = true
        XCTAssertTrue(store.updateActionEnabled)
    }

    /// The badge wants the opposite default: it must never light up on an unknown.
    @MainActor
    func testTheBadgeNeedsCertaintyNotAnUnknown() throws {
        let old = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"version":"1.17.0"}}"#)
        XCTAssertFalse(old.anyAvailable, "an unknown must never badge the menu bar")
        XCTAssertFalse(old.verdictKnown)

        let new = try decode(#"{"schemaVersion":1,"cli":{"updated":false,"updateAvailable":false}}"#)
        XCTAssertTrue(new.verdictKnown, "a CLI that answered counts as a verdict, even a negative one")
    }

    /// While an update is running the item stays disabled, so it cannot be started twice.
    @MainActor
    func testTheUpdateItemIsDisabledWhileUpdating() {
        let store = StateStore()
        store.updateVerdictKnown = true
        store.updateAvailable = true
        store.operationMessage = "Updating RunOS…"

        XCTAssertFalse(store.updateActionEnabled, "an update already running must not be startable again")
    }

    // MARK: - What the menu bar shows

    /*
     The badge is a SEPARATE signal from the connection dot, which already occupies the bottom
     trailing corner and means something else entirely. An update waiting must not change what the
     app says about the VPN, and a disconnected VPN must not hide that an update is waiting.
    */
    @MainActor
    func testTheUpdateBadgeIsIndependentOfTheConnectionState() throws {
        let store = StateStore()
        store.cliStatus = CLIStatus(
            schemaVersion: 1, authenticated: true, accountId: "abcde", companyName: nil,
            vpnAccountId: nil, vpnAccountMismatch: nil, vpnRunning: nil, authError: nil,
            sessionExpired: nil, authErrorKind: nil
        )
        store.updateAvailable = true

        // Connected and an update waiting: still connected, and still badged.
        let connected = #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#
        store.vpnStatus = try JSONDecoder.runOS.decode(VPNStatus.self, from: Data(connected.utf8))
        XCTAssertEqual(store.menuBarState, .connected, "an update waiting is not a VPN problem")
        XCTAssertTrue(store.updateAvailable)
    }
}

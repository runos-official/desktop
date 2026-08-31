import XCTest
@testable import RunOSDesktop

/*
 FPL26. The app's two states, and the edge cases around them.

 The operator said it plainly: these are hard to test on a Mac. Reproducing an account switch, a
 24-hour expiry or a network blip by hand costs a browser round trip and a real tunnel each time, so
 everything reachable from a fixture is asserted here instead.
*/
final class SignInParityTests: XCTestCase {

    // MARK: - Building fixtures

    /// A `runos status` result. Every field is named so a test reads as the situation it describes.
    @MainActor
    private func cli(
        authenticated: Bool,
        authError: String? = nil,
        authErrorKind: String? = nil,
        sessionExpired: Bool? = nil,
        accountId: String? = "abcde",
        vpnAccountId: String? = nil,
        vpnAccountMismatch: Bool? = nil
    ) -> CLIStatus {
        CLIStatus(
            schemaVersion: 1, authenticated: authenticated, accountId: accountId, companyName: nil,
            vpnAccountId: vpnAccountId, vpnAccountMismatch: vpnAccountMismatch, vpnRunning: nil,
            authError: authError, sessionExpired: sessionExpired, authErrorKind: authErrorKind
        )
    }

    @MainActor
    private func vpn(running: Bool, loginRequired: Bool, clusterConnected: Bool = true) throws -> VPNStatus {
        let json = #"{"schemaVersion":1,"running":"# + (running ? "true" : "false")
            + #","session":{"present":"# + (loginRequired ? "false" : "true")
            + #","loginRequired":"# + (loginRequired ? "true" : "false")
            + #"},"clusters":[{"cid":"a1b","name":"lab","connected":"# + (clusterConnected ? "true" : "false")
            + #","reachable":true,"peerUp":true,"peeredWith":[]}]}"#
        return try JSONDecoder.runOS.decode(VPNStatus.self, from: Data(json.utf8))
    }

    // MARK: - The identity, which is the CLI's and nothing else's

    /*
     THE STATE THIS APP COULD NOT PREVIOUSLY EXPRESS.

     Measured on a live machine 2026-08-31: one `runos status` reporting `"authenticated": false`
     and `"vpnRunning": true` together. Sign In ran `vpn up` and Sign Out ran `vpn down`, so the
     app's only notion of being signed in WAS the VPN session, and it drew the tunnel.
    */
    @MainActor
    func testARunningTunnelIsNotASignIn() throws {
        let store = StateStore()
        store.cliStatus = cli(authenticated: false, authError: "Your session has ended.", authErrorKind: "rejected")
        store.vpnStatus = try vpn(running: true, loginRequired: false)

        XCTAssertFalse(store.signedIn)
        XCTAssertTrue(store.signInRequired)
        XCTAssertEqual(store.vpnMenuMode, .signedOut)
        XCTAssertFalse(store.vpnControlsUsable)
        XCTAssertEqual(store.menuBarState, .attention, "a tunnel with no identity behind it is not a connected state")
    }

    /*
     FCR160. `authenticated: false` also covers a refresh that never COMPLETED, and that must not
     put a Sign In button in front of somebody whose session is perfectly good.
    */
    @MainActor
    func testANetworkBlipNeverAsksForASignIn() throws {
        let store = StateStore()
        store.cliStatus = cli(
            authenticated: false,
            authError: "Could not reach the sign-in service. Check your connection; your sign-in is unaffected.",
            authErrorKind: "network"
        )
        store.vpnStatus = try vpn(running: true, loginRequired: false)

        XCTAssertFalse(store.signInRequired, "the sign-in is unknown, not gone")
        XCTAssertNotEqual(store.vpnMenuMode, .signedOut, "and the VPN submenu must not claim otherwise")
    }

    /// An older CLI does not send the kind at all. Absent must read as a real refusal, which is the
    /// behaviour before the field existed, rather than silently suppressing a genuine sign-out.
    @MainActor
    func testAnOlderCLIWithoutTheKindStillReportsASignOut() {
        let store = StateStore()
        store.cliStatus = cli(authenticated: false, authError: "Invalid token", authErrorKind: nil)

        XCTAssertTrue(store.signInRequired)
    }

    /// Nothing read yet. Claiming "signed out" at first launch would be inventing a fact.
    @MainActor
    func testNothingKnownYetIsNotSignedOut() {
        let store = StateStore()

        XCTAssertFalse(store.signedIn)
        XCTAssertFalse(store.signInRequired, "unknown is not signed out")
        XCTAssertEqual(store.vpnMenuMode, .disconnected)
    }

    // MARK: - The tunnel, which is a separate fact

    /*
     The 2026-08-25 defect, and the route it came back by.

     `running` is the tunnel INTERFACE and it stays up through a session expiry. While
     `signInRequired` still meant "the VPN session ended", the menu-bar check happened to be covered
     by it. Separating identity from tunnel took that cover away and the connected icon reappeared
     over a dead path, which is why `vpnConnected` is asserted here directly.
    */
    @MainActor
    func testAnExpiredSessionIsNeverDrawnAsConnected() throws {
        let store = StateStore()
        store.cliStatus = cli(authenticated: true)
        store.vpnStatus = try vpn(running: true, loginRequired: true)

        XCTAssertFalse(store.vpnConnected)
        XCTAssertNotEqual(store.vpnMenuMode, .connected)
        XCTAssertEqual(store.menuBarState, .attention)
        XCTAssertTrue(store.vpnControlsUsable, "they are signed in, so Connect must still be reachable")
    }

    /// Signed in, tunnel down: the one useful action is Connect, and it is offered.
    @MainActor
    func testSignedInWithTheTunnelDownOffersConnect() throws {
        let store = StateStore()
        store.cliStatus = cli(authenticated: true)
        store.vpnStatus = try vpn(running: false, loginRequired: false)

        XCTAssertEqual(store.vpnMenuMode, .disconnected)
        XCTAssertTrue(store.vpnControlsUsable)
    }

    /// The full working state, which is the only one that earns the connected icon.
    @MainActor
    func testSignedInAndConnectedIsTheOnlyConnectedState() throws {
        let store = StateStore()
        store.cliStatus = cli(authenticated: true)
        store.vpnStatus = try vpn(running: true, loginRequired: false)

        XCTAssertEqual(store.vpnMenuMode, .connected)
        XCTAssertEqual(store.menuBarState, .connected)
    }

    /// A tunnel that is up while every connected cluster is dead reaches nothing, so it is not
    /// connected however good the session looks.
    @MainActor
    func testATunnelWithNoWorkingClusterIsNotConnected() throws {
        let store = StateStore()
        store.cliStatus = cli(authenticated: true)
        store.vpnStatus = try vpn(running: true, loginRequired: false, clusterConnected: false)

        XCTAssertNotEqual(store.menuBarState, .connected)
    }

    /// No daemon to carry a tunnel. A separate state from being signed out, with a different
    /// remedy: it is an install, not a browser.
    @MainActor
    func testAMissingServiceLocksTheControlsWithoutAskingForASignIn() throws {
        let store = StateStore()
        store.cliStatus = cli(authenticated: true)
        store.vpnStatus = try vpn(running: false, loginRequired: false)
        store.vpnServiceMissing = true

        XCTAssertFalse(store.vpnControlsUsable)
        XCTAssertFalse(store.signInRequired, "a missing daemon is not a missing sign-in")
    }

    // MARK: - The two purposes, which must never be spelled the same

    /*
     Signing in and confirming a sign-in are different things.

     Wording them the same is what produced "sign in twice": somebody who had signed in a minute
     ago, asking to connect, was shown a window headed "Sign in to RunOS", which reads as the first
     sign-in having failed.
    */
    func testSigningInAndConfirmingAreDifferentCommandsAndDifferentWords() {
        XCTAssertEqual(SignInPurpose.signIn.arguments, DesktopCommands.signIn())
        XCTAssertEqual(SignInPurpose.confirm.arguments, DesktopCommands.setVPN(enabled: true))
        XCTAssertNotEqual(SignInPurpose.signIn.windowTitle, SignInPurpose.confirm.windowTitle)

        // The confirmation must never call itself a sign-in, in the title or the explanation.
        XCTAssertFalse(SignInPurpose.confirm.windowTitle.lowercased().contains("sign in"))
        XCTAssertTrue(SignInPurpose.confirm.explanation.lowercased().contains("still signed in"),
                      "it must say the sign-in is intact, got \(SignInPurpose.confirm.explanation)")
    }

    /// Only `login` may establish an identity, and only `logout` may end one.
    func testOnlyLoginEstablishesAnIdentity() {
        XCTAssertEqual(DesktopCommands.signIn().first, "login")
        XCTAssertEqual(DesktopCommands.signOut(), ["logout"])

        // Connecting is the tunnel and nothing else.
        XCTAssertEqual(DesktopCommands.setVPN(enabled: true).first, "vpn")
        XCTAssertEqual(DesktopCommands.setVPN(enabled: false), ["vpn", "down", "--json"])

        // `--no-browser` on both device-code commands, so THIS app opens the browser on a click and
        // the device code is readable before a window takes the screen.
        XCTAssertTrue(DesktopCommands.signIn().contains("--no-browser"))
        XCTAssertTrue(DesktopCommands.setVPN(enabled: true).contains("--no-browser"))

        // The startup connect must never be able to open one at all.
        XCTAssertTrue(DesktopCommands.connectVPNAtStartup().contains("--non-interactive"))
        XCTAssertFalse(DesktopCommands.connectVPNAtStartup().contains("--no-browser"))
    }

    /*
     A CONNECT MUST NOT FLASH A WINDOW AT SOMEBODY WHO NEEDS NO CONFIRMATION.

     MEASURED 2026-08-31 by clicking Connect in the running app, thirty seconds after signing in.
     Conductor was perfectly happy, so no device code was ever issued, and yet a modal titled
     "Confirm it's you" appeared and vanished on its own. A window that asks you to prove who you
     are and then withdraws the question is worse than no window: it reads as something having gone
     wrong, and it is the common case, because most connects happen right after a sign-in.

     Sign In is the opposite. The person deliberately asked to sign in, a device code is certain to
     come, and the window IS the command; opening it at once is what puts the code on screen before
     any browser can take focus.
    */
    func testConnectingDoesNotOpenAWindowUntilThereIsSomethingToShow() {
        XCTAssertTrue(SignInPurpose.signIn.presentsWindowImmediately,
                      "a sign-in always produces a device code, and the window is the command")
        XCTAssertFalse(SignInPurpose.confirm.presentsWindowImmediately,
                       "a connect usually needs no confirmation, so the window must wait for a code")
    }

    /// While a connect runs windowless, the menu still has to say something is happening.
    func testAWindowlessConnectStillReportsItselfInTheMenu() {
        XCTAssertFalse(SignInPurpose.confirm.busyMessage.isEmpty,
                       "a silent connect with no progress anywhere looks like a dead click")
        XCTAssertTrue(SignInPurpose.confirm.busyMessage.lowercased().contains("connect"),
                      "it must name what it is doing, got \(SignInPurpose.confirm.busyMessage)")
        XCTAssertFalse(SignInPurpose.confirm.busyMessage.lowercased().contains("sign in"),
                       "connecting is not signing in, got \(SignInPurpose.confirm.busyMessage)")
    }

    // MARK: - Connecting automatically

    /*
     REPORTED 2026-08-31: "i have connect vpn at startup selected, but after logging in, it doesn't
     auto connect."

     It fired exactly once, in the app's init, and nowhere else. On a machine that launches the app
     at login that means it ran while the person was still signed out, `vpn up --non-interactive`
     refused because there was no identity, and nothing ever retried. The setting looked broken
     precisely when it was most wanted: the first connect of the day.

     The preference means "connect when you can", so it fires again at the moment an identity
     becomes usable, which is a sign-in completing.
    */
    func testAutoConnectFiresWhenASignInMakesItPossible() {
        XCTAssertTrue(AutoConnect.shouldConnect(enabled: true, wasSignedIn: false, isSignedIn: true, tunnelRunning: false),
                      "signing in is the moment the setting exists for")
    }

    /// Off is off. Bringing up a tunnel nobody asked for was itself a report.
    func testAutoConnectDoesNothingWhenTheSettingIsOff() {
        XCTAssertFalse(AutoConnect.shouldConnect(enabled: false, wasSignedIn: false, isSignedIn: true, tunnelRunning: false))
    }

    /*
     A MANUAL DISCONNECT MUST STICK, and this is the case that makes the rule a TRANSITION rather
     than a state.

     "signed in and the tunnel is down" is true immediately after somebody clicks Disconnect. Acting
     on that would reconnect them within seconds, over and over, and there would be no way to turn
     the VPN off without turning the setting off first.
    */
    func testAutoConnectNeverUndoesAManualDisconnect() {
        XCTAssertFalse(AutoConnect.shouldConnect(enabled: true, wasSignedIn: true, isSignedIn: true, tunnelRunning: false),
                       "already signed in is not a new sign-in; the person just disconnected")
    }

    /// First observation of all, at app launch. The startup connect in the app's init owns that
    /// moment; acting here as well would run two connects over each other.
    func testAutoConnectLeavesTheFirstObservationToStartup() {
        XCTAssertFalse(AutoConnect.shouldConnect(enabled: true, wasSignedIn: nil, isSignedIn: true, tunnelRunning: false))
    }

    /// Nothing to do when it is already up.
    func testAutoConnectDoesNothingWhenTheTunnelIsAlreadyUp() {
        XCTAssertFalse(AutoConnect.shouldConnect(enabled: true, wasSignedIn: false, isSignedIn: true, tunnelRunning: true))
    }

    /// Signing OUT is not a reason to connect anything.
    func testAutoConnectIgnoresASignOut() {
        XCTAssertFalse(AutoConnect.shouldConnect(enabled: true, wasSignedIn: true, isSignedIn: false, tunnelRunning: false))
    }

    /*
     The label has to say what it does. "at Startup" is why the report reads as a bug rather than a
     misunderstanding: the person ticked a box that promised a connection and did not get one.
    */
    func testTheSettingIsNamedForWhatItDoes() {
        XCTAssertFalse(AutoConnect.menuLabel.lowercased().contains("startup"),
                       "it no longer only happens at startup, got \(AutoConnect.menuLabel)")
        XCTAssertTrue(AutoConnect.menuLabel.lowercased().contains("automatic"),
                      "got \(AutoConnect.menuLabel)")
    }

    // MARK: - The CLI's own words

    /*
     stderr used to go to `nullDevice`, so every failure after the browser authorised became one
     generic line. The CLI writes a remedy on that stream and it is almost always the whole answer.
    */
    func testAFailureIsReportedInTheCLIsOwnWords() {
        let result = CLIStreamResult(
            exitCode: 1,
            errorOutput: "This VPN session needs a fresh sign-in.\nyou are not signed in. Run 'runos login' first\n"
        )

        XCTAssertEqual(result.failureSentence, "you are not signed in. Run 'runos login' first",
                       "the LAST non-empty line is the one carrying the remedy")
    }

    /// Trailing blank lines and whitespace must not become the message.
    func testTrailingBlankLinesAreNotTheMessage() {
        let result = CLIStreamResult(exitCode: 1, errorOutput: "the real sentence\n\n   \n\n")

        XCTAssertEqual(result.failureSentence, "the real sentence")
    }

    /// A CLI that said nothing leaves the app to word it, per purpose, and the two differ.
    func testSilenceFallsBackToWordingThatMatchesThePurpose() {
        let silent = CLIStreamResult(exitCode: 1, errorOutput: "")

        XCTAssertNil(silent.failureSentence)
        XCTAssertNotEqual(SignInPurpose.signIn.genericFailure, SignInPurpose.confirm.genericFailure)
        XCTAssertFalse(SignInPurpose.confirm.genericFailure.lowercased().contains("sign in"),
                       "a failed CONNECT must not be reported as a failed sign-in")
    }

    // MARK: - The event stream

    /*
     The signed-out event the CLI now writes to stdout. RunOS Desktop's Sign In button used to run a
     command that exited with an empty stdout, so this exact line is what turned a dead end into a
     remedy. Asserted here because the app is the only consumer.
    */
    func testTheSignedOutEventIsUnderstood() {
        let line = #"{"event":"error","reason":"not_signed_in","message":"you are not signed in. Run 'runos login' first, then 'runos vpn up'"}"#

        guard case .failed(let reason, let message)? = SignInEvent.parse(line) else {
            return XCTFail("the signed-out event must parse as a failure")
        }
        XCTAssertEqual(reason, "not_signed_in")
        XCTAssertTrue(message.contains("runos login"))
    }

    /// An event this build has never heard of must not break a sign-in in progress.
    func testAnUnknownEventIsIgnoredRatherThanFatal() {
        XCTAssertNil(SignInEvent.parse(#"{"event":"something_new","detail":"whatever"}"#))
        XCTAssertNil(SignInEvent.parse("not json at all"))
        XCTAssertNil(SignInEvent.parse(""))
    }
}

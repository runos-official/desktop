import XCTest
@testable import RunOSDesktop

/*
 Telling "the VPN service is not installed" apart from every other CLI refusal.

 Getting this wrong is what shipped: every failure was read as a sign-in problem, so a machine with
 no daemon sent the person to a browser and then appeared to do nothing. The classification is the
 whole fix, so it is pinned against the CLI's real sentences rather than a paraphrase.
*/
final class VPNServiceTests: XCTestCase {
    private func cliError(_ message: String) -> CLIExecutionError {
        CLIExecutionError(exitCode: 1, message: message)
    }

    // The exact sentence the CLI prints, copied from a real run on 2026-08-25.
    func testRecognisesTheRealRefusal() {
        let real = "Error: the RunOS VPN service is not running (/var/run/runos-vpn.sock). Run 'sudo runos vpn install' first."
        XCTAssertTrue(VPNService.isMissing(cliError(real)))
    }

    // Either half is enough, so a reworded error still lands as long as one survives.
    func testRecognisesTheSocketPathAlone() {
        XCTAssertTrue(VPNService.isMissing(cliError("cannot reach /var/run/runos-vpn.sock")))
    }

    func testRecognisesTheRemedyAlone() {
        XCTAssertTrue(VPNService.isMissing(cliError("run sudo runos VPN Install to continue")))
    }

    // A sign-in problem must NOT be read as a missing service: the remedies share nothing, and
    // offering the wrong one is the defect being fixed.
    func testDoesNotClaimAnExpiredSessionIsAMissingService() {
        XCTAssertFalse(VPNService.isMissing(cliError("Error: your session has expired. Run 'runos login'.")))
    }

    func testDoesNotClaimAnArbitraryFailureIsAMissingService() {
        XCTAssertFalse(VPNService.isMissing(cliError("Error: cluster v6b was not found.")))
    }

    // A home directory with a space in it is ordinary on macOS, and an unquoted path would run the
    // installer as the wrong command under an administrator prompt.
    func testShellQuotingSurvivesASpaceInThePath() {
        let quoted = VPNService.shellQuoted("/Users/some one/.local/bin/runos")
        XCTAssertEqual(quoted, "'/Users/some one/.local/bin/runos'")
    }

    func testShellQuotingClosesAndReopensAroundAQuote() {
        XCTAssertEqual(VPNService.shellQuoted("a'b"), "'a'\\''b'")
    }

    // The command is embedded in an AppleScript string literal, so its quotes and backslashes have
    // to survive that layer as well as the shell one.
    func testAppleScriptQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(VPNService.appleScriptQuoted("say \"hi\""), "say \\\"hi\\\"")
        XCTAssertEqual(VPNService.appleScriptQuoted("back\\slash"), "back\\\\slash")
    }
}

/*
 The install command, which has to carry SUDO_USER.

 Without it the socket is created as root:wheel and the person who just installed the service
 cannot open it, because an ordinary macOS account is in staff and admin and not wheel. The daemon
 runs and `vpn status` still says it is not running.
*/
extension VPNServiceTests {
    func testInstallCommandCarriesSudoUserSoTheSocketIsReachable() {
        let command = VPNService.installCommand(cliPath: "/Users/dev/.local/bin/runos", userName: "dev")
        XCTAssertTrue(command.hasPrefix("SUDO_USER='dev' "), command)
        XCTAssertTrue(command.hasSuffix("vpn install"), command)
    }

    func testInstallCommandQuotesBothThePathAndTheUser() {
        let command = VPNService.installCommand(cliPath: "/Users/some one/bin/runos", userName: "some one")
        XCTAssertEqual(command, "SUDO_USER='some one' '/Users/some one/bin/runos' vpn install")
    }
}

import XCTest
@testable import RunOSDesktop

/*
The VPN service runs the same binary the CLI updates, and launchd holds the old inode open, so
updating the CLI leaves the daemon on the previous build until something restarts it.

A person updating from the MENU was never told. The CLI prints the notice, but `--json` moves it to
stderr so it cannot corrupt the stream, and the app reads stderr only when a command FAILS. So the
update reported success and the VPN quietly went on running old code, with every field the newer
build added decoding as empty across the socket.

The drift is computable here with nothing new from the CLI: the app already reads `--version` and
`vpn status --json`, and the daemon reports its own build in that payload.
*/

@MainActor
final class VPNRestartRequiredTests: XCTestCase {
    private func store(cli: String?, daemon: String?, running: Bool = true) -> StateStore {
        let s = StateStore()
        s.cliVersion = cli
        let daemonJSON = daemon.map { "\"version\":\"\($0)\"," } ?? ""
        s.vpnStatus = try? JSONDecoder.runOS.decode(
            VPNStatus.self,
            from: Data("{\"schemaVersion\":2,\(daemonJSON)\"running\":\(running),\"session\":{\"present\":true,\"loginRequired\":false},\"clusters\":[]}".utf8))
        return s
    }

    // THE CASE THIS EXISTS FOR: the CLI was updated, the daemon still runs what it ran before.
    func testADaemonOnAnotherBuildAsksForARestart() {
        XCTAssertTrue(store(cli: "1.18.2", daemon: "1.18.1").vpnRestartRequired)
    }

    // The ordinary state. Nothing to say, and saying it would put a permanent item in the menu.
    func testMatchingBuildsAskForNothing() {
        XCTAssertFalse(store(cli: "1.18.2", daemon: "1.18.2").vpnRestartRequired)
    }

    /*
     Everything that must NOT produce the item.

     A menu entry that appears when it cannot help is worse than no entry: it asks for an
     administrator password for a restart that changes nothing.
    */
    func testNothingElseAsksForARestart() {
        // No VPN service at all: there is no daemon to restart.
        XCTAssertFalse(store(cli: "1.18.2", daemon: nil).vpnRestartRequired)
        // A daemon too old to report its build cannot be compared, so nothing is claimed.
        XCTAssertFalse(store(cli: "1.18.2", daemon: "").vpnRestartRequired)
        // The app has not read its own version yet, which is true for the first moment of a launch.
        XCTAssertFalse(store(cli: nil, daemon: "1.18.1").vpnRestartRequired)
        // No status at all, which is what a machine with no VPN service looks like.
        let bare = StateStore()
        bare.cliVersion = "1.18.2"
        XCTAssertFalse(bare.vpnRestartRequired)
    }

    /*
     A DAEMON THAT IS NOT RUNNING IS NOT RESTARTED EITHER.

     `runos vpn status` answers with a stopped tunnel on a machine where the service is installed
     and simply not connected, and the daemon still reports its build. Offering a restart there is
     harmless but pointless: the drift resolves itself the next time it starts.
    */
    func testAStoppedTunnelStillReportsTheDriftItHas() {
        // The service exists and its build differs, so the item is still correct: the daemon
        // process is loaded by launchd whether or not a tunnel is up.
        XCTAssertTrue(store(cli: "1.18.2", daemon: "1.18.1", running: false).vpnRestartRequired)
    }

    // The label is the action, because the item appears only when the action is needed. Its
    // presence is the message; the words do not have to carry it as well.
    func testTheMenuItemIsNamedForWhatItDoes() {
        XCTAssertEqual(MenuPresentation.vpnRestartTitle, "Restart VPN")
    }

    /*
     The command run under the administrator prompt.

     `vpn restart` and NOT `vpn install`: reinstalling rewrites the service definition, which would
     recompute the socket group from whoever is behind the prompt, and this is meant to reload the
     binary and nothing else.

     No SUDO_USER either, unlike install. Install needs it because it derives the socket group from
     the person installing; a restart rewrites nothing that depends on who asked.
    */
    func testTheRestartRunsTheRightCommand() {
        let command = VPNService.restartCommand(cliPath: "/Users/someone/.local/bin/runos")

        XCTAssertEqual(command, "'/Users/someone/.local/bin/runos' vpn restart")
        XCTAssertFalse(command.contains("SUDO_USER"))
        XCTAssertFalse(command.contains("install"))
    }

    // A path with a space in it is the ordinary case on macOS, and it goes through /bin/sh inside
    // an AppleScript string, so it is quoted at both layers.
    func testAPathWithASpaceSurvivesBothQuotingLayers() {
        let command = VPNService.restartCommand(cliPath: "/Users/a b/.local/bin/runos")

        XCTAssertEqual(command, "'/Users/a b/.local/bin/runos' vpn restart")
        XCTAssertFalse(VPNService.appleScriptQuoted(command).contains("\u{22}"))
    }
}

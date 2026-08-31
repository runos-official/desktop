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
     A TUNNEL THAT IS DOWN STILL HAS DRIFT, because the daemon is loaded either way.

     `running` describes the TUNNEL, not the process: launchd keeps the daemon loaded on a machine
     where the service is installed and simply not connected, and it still answers with its build.
     The drift does not resolve itself by waiting, so the item is correct here.
    */
    func testAStoppedTunnelStillReportsTheDriftItHas() {
        XCTAssertTrue(store(cli: "1.18.2", daemon: "1.18.1", running: false).vpnRestartRequired)
    }

    // The label is the action, because the item appears only when the action is needed. Its
    // presence is the message; the words do not have to carry it as well.
    func testTheMenuItemIsNamedForWhatItDoes() {
        XCTAssertEqual(MenuPresentation.vpnRestartTitle, "Restart VPN")
    }

    /*
     WHEN AN UPDATE MAY RAISE THE PASSWORD PROMPT BY ITSELF.

     The prompt is welcome the moment somebody clicks Update, because they are watching. It is not
     welcome at any other time: it takes a password and drops the tunnel.

     The row that matters is the second. The condition used to be "is there drift now", so an Update
     click that replaced nothing still prompted, which overruled a refusal made an hour earlier. It
     is reachable: declining leaves the drift by design, and Update RunOS stays clickable whenever
     the release feed could not be reached, because an unknown verdict enables it rather than
     disabling the only way to update.
    */
    func testOnlyAnUpdateThatReplacedTheCLIMayPromptByItself() {
        for (succeeded, replaced, drift, want) in [
            (true, true, true, true),      // the case it exists for
            (true, false, true, false),    // THE DEFECT: drift somebody already declined
            (true, true, false, false),    // nothing to restart
            (false, true, true, false),    // the update failed; its own message is what matters
        ] as [(Bool, Bool, Bool, Bool)] {
            let got = StateStore.shouldOfferRestartAfterUpdate(
                succeeded: succeeded, replacedTheCLI: replaced, driftPresent: drift)
            XCTAssertEqual(got, want, "succeeded=\(succeeded) replaced=\(replaced) drift=\(drift)")
        }
    }

    /*
     A SERVICE THIS APP IS RESTARTING IS NOT A SERVICE THAT IS MISSING.

     `vpn restart` returns as soon as launchd relaunches the job, but the new daemon binds its socket
     only after resuming: a tun interface, a conductor poll, a DNS apply. A read inside that window
     gets "not running" for the socket, which is otherwise exactly what an absent service looks
     like. The menu then offered "Install VPN Service" seconds after somebody paid a password to
     restart it, and taking that offer rewrites the service definition, which is the one thing
     `vpn restart` was chosen to avoid.
    */
    func testAServiceBeingRestartedIsNotReportedMissing() {
        XCTAssertFalse(StateStore.isServiceGenuinelyMissing(looksMissing: true, restartInProgress: true))
        // And a genuinely absent service is still reported, or the offer to install it disappears.
        XCTAssertTrue(StateStore.isServiceGenuinelyMissing(looksMissing: true, restartInProgress: false))
        XCTAssertFalse(StateStore.isServiceGenuinelyMissing(looksMissing: false, restartInProgress: false))
    }

    /*
     THE DIALOG HAS TO SAY WHAT IT WANTS AND WHY.

     It read "osascript wants to make changes", with no reason given. `osascript` is named because
     the app SPAWNED it: macOS attributes an authorisation request to the process that asked, and
     that was /usr/bin/osascript rather than this app. A generic scripting tool asking for
     administrator rights, with no explanation, is exactly the prompt somebody should refuse.

     Two changes. The script now runs in-process, so the requester is this app and the dialog names
     it. And `do shell script` takes a `with prompt` clause, whose text appears above the password
     field, so the dialog states its business.
    */
    func testTheAdministratorPromptExplainsItself() {
        let restart = VPNService.privilegedScript(
            command: "'/bin/runos' vpn restart", prompt: VPNService.restartPrompt)

        XCTAssertTrue(restart.contains("with prompt"), restart)
        XCTAssertTrue(restart.contains("with administrator privileges"), restart)
        // The reason, in the words a person reads on the dialog.
        XCTAssertTrue(VPNService.restartPrompt.contains("VPN"), VPNService.restartPrompt)
        XCTAssertTrue(VPNService.installPrompt.contains("VPN"), VPNService.installPrompt)
        // Two different actions must not share one sentence: the dialog is the only place a person
        // is told which of them they are approving.
        XCTAssertNotEqual(VPNService.restartPrompt, VPNService.installPrompt)
    }

    /*
     A prompt string is TEXT ON A DIALOG, so a quote in it must not end the AppleScript literal.

     The command is already quoted at two layers. The prompt is a third string going into the same
     literal, and it is the one most likely to be reworded later by somebody not thinking about
     escaping.
    */
    func testAQuoteInThePromptCannotBreakOutOfTheScript() {
        let script = VPNService.privilegedScript(
            command: "'/bin/runos' vpn restart", prompt: "a \"quoted\" word and a \\ backslash")

        // Every quote that belongs to the prompt is escaped, so the only bare quotes are the four
        // delimiting the two literals.
        let bareQuotes = script.enumerated().filter { index, ch in
            ch == "\"" && (index == 0 || Array(script)[index - 1] != "\\")
        }
        XCTAssertEqual(bareQuotes.count, 4, "unbalanced quoting in: \(script)")
    }

    // -128 is osascript's code for "the person pressed Cancel". It is a refusal, not a fault, and
    // it must not surface as an error banner. Kept working across the move to in-process execution,
    // where the code arrives in an NSAppleScript error dictionary rather than on stderr.
    func testCancellingThePromptIsNotReportedAsAFailure() {
        XCTAssertTrue(VPNService.isUserCancellation(code: -128, message: ""))
        XCTAssertTrue(VPNService.isUserCancellation(code: 1, message: "User canceled."))
        XCTAssertFalse(VPNService.isUserCancellation(code: 1, message: "launchctl: no such process"))
        XCTAssertFalse(VPNService.isUserCancellation(code: 0, message: ""))
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

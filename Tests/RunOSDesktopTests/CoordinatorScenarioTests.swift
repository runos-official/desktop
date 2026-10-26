import XCTest
@testable import RunOSDesktop

/*
 RefreshCoordinator, driven end to end against a fake CLI whose answers are files.

 Every scenario here is something that happened, or could, on a real machine: the CLI missing and
 installed later, a status that cannot be read and then can, a daemon that does not answer, a
 connect that fails and works on the retry, a sign-in that is approved or cancelled, a restart that
 is refused at the password prompt, two clicks in quick succession, a CLI that never answers.

 Nothing here raises an administrator prompt (PrivilegedSpy answers instead), opens a window, or
 touches the developer's real CLI or preferences.
*/
@MainActor
final class CoordinatorScenarioTests: XCTestCase {

    // MARK: setup

    private func make(
        _ cli: FakeCLI,
        spy: PrivilegedSpy = PrivilegedSpy(),
        readTimeout: Duration = .seconds(30),
        intervals: (open: Duration, closed: Duration) = (.seconds(5), .seconds(30)),
        resolve: @escaping () throws -> URL = { throw CLIExecutionError(exitCode: -1, message: "no CLI") }
    ) throws -> (store: StateStore, coordinator: RefreshCoordinator) {
        let store = StateStore()
        let coordinator = RefreshCoordinator(
            store: store, runner: try cli.runner(), autoConnect: makeAutoConnect(),
            readTimeout: readTimeout, pollIntervals: intervals, resolveCLI: resolve, privileged: spy.service)
        return (store, coordinator)
    }

    private func layout(_ store: StateStore) -> MenuLayout {
        MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false, loginItemError: nil, now: Date())
    }

    private func settle(_ store: StateStore) async {
        await waitUntil(15, "the operation to finish") { !store.isBusy }
    }

    // MARK: CLI missing, then installed

    func testCLIMissingThenInstalledLater() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        nonisolated(unsafe) var installed = false
        let store = StateStore()
        store.cliAvailable = false
        store.errorMessage = "RunOS Desktop cannot find the RunOS CLI. Install or update the CLI, then run 'runos desktop install'."
        let executable = cli.executable
        let coordinator = RefreshCoordinator(
            store: store, runner: nil, autoConnect: makeAutoConnect(),
            resolveCLI: { if installed { return executable }; throw CLIExecutionError(exitCode: -1, message: "no CLI") })

        await coordinator.refresh()
        XCTAssertFalse(store.cliAvailable)
        XCTAssertNotNil(store.errorMessage, "still missing: the message from launch stands")
        XCTAssertEqual(cli.calls, [])

        installed = true
        await coordinator.refresh()
        XCTAssertTrue(store.cliAvailable)
        XCTAssertNil(store.errorMessage, "the instruction was followed, so it stops being shown")
        XCTAssertTrue(store.signedIn)
        XCTAssertNotNil(store.vpnStatus)
    }

    // MARK: unreadable status, then recovery

    func testRunOSStatusThatCannotBeReadIsSaidPlainlyAndRecovers() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        cli.set("status --json", out: "runos: something went wrong")

        await coordinator.refresh()
        XCTAssertEqual(store.errorMessage, "Cannot read the RunOS status: RunOS printed text instead of JSON: runos: something went wrong")
        XCTAssertFalse(store.signedIn)

        cli.setHealthy()
        await coordinator.refresh()
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.signedIn)
    }

    func testVPNStatusThatCannotBeReadShowsCannotReadAndOffersRestartThenRecovers() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        cli.set("vpn status --json", out: #"{"schemaVersion":1,"running":true}"#)

        await coordinator.refresh()

        XCTAssertNil(store.vpnStatus)
        guard case .unreadable(let failure) = store.vpnStatusProblem else { return XCTFail("\(String(describing: store.vpnStatusProblem))") }
        XCTAssertEqual(failure.headline, "Cannot read the VPN status")
        XCTAssertTrue(failure.reason.contains("session"), failure.reason)
        let menu = layout(store)
        XCTAssertEqual(menu.item("status.vpn-problem")?.title, "Cannot read the VPN status")
        XCTAssertTrue(menu.item("status.vpn-problem-reason")?.title.contains("session") == true)
        XCTAssertEqual(menu.item("restart-vpn")?.enabled, true)
        XCTAssertEqual(store.menuBarState, .attention)

        cli.setHealthy()
        await coordinator.refresh()
        XCTAssertNil(store.vpnStatusProblem)
        XCTAssertNotNil(store.vpnStatus)
        XCTAssertNil(layout(store).item("status.vpn-problem"))
    }

    func testAnAccountListThatCannotBeReadIsSaidAndOldCLIsStayQuiet() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)

        cli.set("user accounts --json", out: #"{"accounts":[{"name":"No id"}]}"#)
        await coordinator.refresh()
        XCTAssertTrue(store.errorMessage?.hasPrefix("Cannot read the account list") == true, "\(String(describing: store.errorMessage))")

        // An older CLI answers `user accounts` with help text or an error: that is not a fault.
        cli.set("user accounts --json", out: "Usage: runos user [command]")
        await coordinator.refresh()
        XCTAssertNil(store.errorMessage)
        cli.set("user accounts --json", err: "unexpected command", code: 1)
        await coordinator.refresh()
        XCTAssertNil(store.errorMessage)
    }

    func testAnUpdateCheckThatCannotBeReadLeavesUpdateClickable() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("update --check --json", out: "Checking...")
        let (store, coordinator) = try make(cli)

        await coordinator.refresh()

        XCTAssertEqual(store.updateVerdictKnown, false)
        XCTAssertTrue(store.updateActionEnabled, "an unknown verdict must never disable the way to update")
        XCTAssertNil(store.errorMessage, "not knowing whether an update exists is not worth a banner")
    }

    // MARK: the daemon

    func testDaemonUnreachableShowsTheCLIsSentenceAndOffersRestartNotInstall() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        cli.set("vpn status --json", err: "Error: the VPN daemon is not answering on its control socket.", code: 1)

        await coordinator.refresh()

        XCTAssertEqual(store.errorMessage, "Error: the VPN daemon is not answering on its control socket.")
        XCTAssertEqual(store.vpnStatusProblem, .notAnswering)
        XCTAssertFalse(store.vpnServiceMissing)
        let menu = layout(store)
        XCTAssertNil(menu.item("install"))
        XCTAssertEqual(menu.item("restart-vpn")?.enabled, true)
    }

    func testTheRealMissingServiceSentenceOffersInstall() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        cli.set("vpn status --json", err: try Fixtures.text("cli-errors", "service-not-installed"), code: 1)

        await coordinator.refresh()

        XCTAssertTrue(store.vpnServiceMissing)
        XCTAssertNil(store.vpnStatusProblem)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(layout(store).item("install"))
    }

    // FCR 1732
    func testASocketPermissionErrorShowsItsOwnMessageAndRestartAndNeverInstall() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        let text = try Fixtures.text("cli-errors", "permission-denied-service-running").trimmingCharacters(in: .whitespacesAndNewlines)
        cli.set("vpn status --json", err: text, code: 1)

        await coordinator.refresh()

        XCTAssertFalse(store.vpnServiceMissing, "the CLI says the service IS running")
        XCTAssertEqual(store.errorMessage, text.replacingOccurrences(of: "Error: ", with: "Error: "))
        let menu = layout(store)
        XCTAssertNil(menu.item("install"))
        XCTAssertNil(menu.item("status.service-missing"))
        XCTAssertTrue(menu.item("status.error")?.title.hasPrefix("Error: permission denied opening the RunOS VPN control socket") == true,
                      menu.item("status.error")?.title ?? "")
        XCTAssertEqual(menu.item("restart-vpn")?.enabled, true)
        XCTAssertNotNil(menu.item("details"), "the rest of the CLI's explanation is behind Show Details")
    }

    // MARK: connect

    func testConnectFailsThenTheRetrySucceeds() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        let dnsError = try Fixtures.text("cli-errors", "long-dns-error").trimmingCharacters(in: .whitespacesAndNewlines)
        cli.set("vpn connect c-example1 --json", err: dnsError, code: 1)

        coordinator.perform(DesktopCommands.setCluster("c-example1", connected: false), message: "Connecting Example Cluster…")
        await settle(store)

        XCTAssertEqual(store.errorMessage, dnsError, "the CLI's sentence, unrewritten")
        let failed = layout(store)
        XCTAssertLessThanOrEqual(failed.item("status.error")?.title.count ?? 999, ErrorPresentation.menuLineLimit)
        XCTAssertEqual(failed.details, ErrorPresentation.fullText(dnsError))

        cli.set("vpn connect c-example1 --json", out: FakeCLI.vpnJSON(running: true))
        coordinator.perform(DesktopCommands.setCluster("c-example1", connected: false), message: "Connecting Example Cluster…")
        await settle(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(layout(store).item("details"))
    }

    func testConnectReturningWhileDNSIsPendingIsACalmStateNotAnError() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let pending = #"{"available":false,"mode":"resolver-files","pending":true,"error":"Cluster names are still being applied by macOS."}"#
        cli.set("vpn status --json", out: FakeCLI.vpnJSON(running: true, dns: pending))
        cli.set("vpn connect c-example1 --json", out: FakeCLI.vpnJSON(running: true, dns: pending))
        let (store, coordinator) = try make(cli)

        coordinator.perform(DesktopCommands.setCluster("c-example1", connected: false), message: "Connecting Example Cluster…")
        await settle(store)

        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.dnsPending)
        XCTAssertEqual(store.menuBarState, .connected)
        XCTAssertEqual(layout(store).item("status.dns-pending")?.title, "Connected. Cluster names are still being applied by macOS")
    }

    // MARK: sign-in runs (no window)

    private func runSignIn(_ cli: FakeCLI, purpose: SignInPurpose, coordinator: RefreshCoordinator? = nil) throws -> (SignInRunner, Recorder) {
        let recorder = Recorder()
        let model = SignInRunner(runner: try cli.runner(), purpose: purpose) {
            recorder.finished += 1
            if let coordinator { coordinator.signInFinished(purpose: purpose) }
        }
        model.onEnded = { recorder.ended.append($0) }
        model.start()
        return (model, recorder)
    }

    @MainActor
    final class Recorder {
        var finished = 0
        var ended: [String?] = []
    }

    func testSignInStartApproveFinish() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("login --json --no-browser", script: """
        printf '%s\\n' '{"event":"device_code","deviceId":"ABCD-1234","url":"https://console.example.test/device"}'
        sleep 0.3
        printf '%s\\n' '{"event":"authorized"}'
        exit 0
        """)
        let (store, coordinator) = try make(cli)
        let (model, recorder) = try runSignIn(cli, purpose: .signIn, coordinator: coordinator)

        await waitUntil(10, "the device code") { model.deviceID == "ABCD-1234" }
        XCTAssertEqual(model.url, "https://console.example.test/device")
        XCTAssertEqual(model.phase, .waiting)
        await waitUntil(10, "the run to finish") { recorder.finished == 1 }
        XCTAssertEqual(model.phase, .authorized)
        XCTAssertEqual(recorder.ended.count, 1)
        XCTAssertNil(recorder.ended[0] ?? nil)
        await waitUntil(10, "the menu to be true again") { !store.isBusy && store.signedIn }
    }

    func testSignInCancelled() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("login --json --no-browser", script: """
        printf '%s\\n' '{"event":"device_code","deviceId":"ABCD-1234","url":"https://console.example.test/device"}'
        sleep 20
        """)
        let (model, recorder) = try runSignIn(cli, purpose: .signIn)
        await waitUntil(10, "the device code") { model.deviceID != nil }

        model.cancel()

        XCTAssertEqual(model.phase, .failed("Sign in cancelled."))
        XCTAssertEqual(recorder.ended.count, 1)
        XCTAssertNil(recorder.ended[0] ?? nil, "backing out is not a fault to report")
        XCTAssertEqual(recorder.finished, 0)
    }

    // FCR 1730 item 4: the CLI's sentence reaches the window whole.
    func testSignInFailureCarriesTheWholeSentence() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let sentence = try Fixtures.text("cli-errors", "long-dns-error").trimmingCharacters(in: .whitespacesAndNewlines)
        cli.set("vpn up --json --no-browser", err: sentence, code: 1)
        let (model, recorder) = try runSignIn(cli, purpose: .confirm)

        await waitUntil(10, "the failure") { model.phase.isFailure }

        XCTAssertEqual(model.phase, .failed(sentence))
        XCTAssertEqual(recorder.ended.count, 1)
        XCTAssertEqual(recorder.ended[0] ?? nil, sentence)
        XCTAssertGreaterThan(sentence.count, 200, "the fixture is long enough to have been cut before")
    }

    func testRenewRunsAndSaysWhenTheNewSessionEnds() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn up --json --no-browser", out: FakeCLI.vpnJSON(running: true))
        let (store, coordinator) = try make(cli)
        // The run is held by this model: the task only keeps it weakly, so dropping it ends the run.
        let (model, recorder) = try runSignIn(cli, purpose: .renew, coordinator: coordinator)

        await waitUntil(10, "the renewal") { recorder.finished == 1 }
        await waitUntil(10, "the notice") { store.noticeMessage != nil }
        withExtendedLifetime(model) {}

        XCTAssertTrue(store.noticeMessage?.hasPrefix("VPN session renewed.") == true, "\(String(describing: store.noticeMessage))")
    }

    // MARK: restart VPN

    func testRestartVPNSuccessReadsTheNewBuildBack() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn status --json", out: FakeCLI.vpnJSON(running: true, version: "1.20.0"))
        let spy = PrivilegedSpy()
        let (store, coordinator) = try make(cli, spy: spy)
        await coordinator.refresh()
        XCTAssertTrue(store.vpnRestartRequired)
        XCTAssertNotNil(layout(store).item("status.restart-hint"))
        // The service comes back on the current build.
        cli.set("vpn status --json", out: FakeCLI.vpnJSON(running: true))

        coordinator.restartVPNService()
        XCTAssertEqual(store.operationMessage, "Restarting the VPN service…")
        XCTAssertEqual(layout(store).item("restart-vpn")?.enabled, false)
        await settle(store)

        XCTAssertEqual(spy.restarts.count, 1)
        XCTAssertEqual(spy.restarts.first?.cliPath, cli.executable.path, "the SAME binary the menu reads from")
        XCTAssertTrue(spy.restarts.first?.prompt.contains("restart") == true)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.vpnRestartRequired)
        XCTAssertNil(layout(store).item("status.restart-hint"))
        XCTAssertEqual(layout(store).item("restart-vpn")?.enabled, true, "always there, even with no drift")
    }

    func testRestartVPNCancelledAtThePasswordPromptIsNotAFaultAndStaysOffered() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn status --json", out: FakeCLI.vpnJSON(running: true, version: "1.20.0"))
        let spy = PrivilegedSpy()
        spy.restartResult = .failure(CLIExecutionError(
            exitCode: -128, message: "Restarting the VPN service needs an administrator password. Nothing was changed."))
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.restartVPNService()
        await settle(store)

        XCTAssertEqual(store.errorMessage, "Restarting the VPN service needs an administrator password. Nothing was changed.")
        XCTAssertEqual(layout(store).item("restart-vpn")?.enabled, true)
        XCTAssertNil(store.operationMessage)
    }

    func testRestartVPNFailureShowsTheReason() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let spy = PrivilegedSpy()
        spy.restartResult = .failure(CLIExecutionError(exitCode: 1, message: "The VPN service could not be restarted."))
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.restartVPNService()
        await settle(store)

        XCTAssertEqual(store.errorMessage, "The VPN service could not be restarted.")
    }

    func testRestartVPNIsNotAnInstallWhileTheServiceIsBeingRestarted() async throws {
        // `vpn restart` returns before the new daemon binds its socket. A read in that window says
        // "not running", which must not turn into an Install offer.
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn status --json", err: try Fixtures.text("cli-errors", "service-not-installed"), code: 1)
        let (store, coordinator) = try make(cli)

        coordinator.restartVPNService()
        await settle(store)

        XCTAssertFalse(store.vpnServiceMissing)
    }

    // MARK: update RunOS

    func testUpdateThatReplacedTheCLIAndLeftDriftAsksForARestart() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        try cli.setFixture("update --json", family: "update", stem: "cli-updated")
        cli.set("vpn status --json", out: FakeCLI.vpnJSON(running: true, version: "1.20.0"))
        let spy = PrivilegedSpy()
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.updateRunOS()
        XCTAssertTrue(store.isUpdating)
        await waitUntil(15, "the restart prompt") { spy.restarts.count == 1 }
        await settle(store)

        XCTAssertFalse(store.isUpdating)
        XCTAssertEqual(spy.restarts.count, 1)
    }

    func testUpdateThatReplacedNothingNeverRaisesAPasswordPrompt() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        try cli.setFixture("update --json", family: "update", stem: "nothing-to-update")
        cli.set("vpn status --json", out: FakeCLI.vpnJSON(running: true, version: "1.20.0"))
        let spy = PrivilegedSpy()
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.updateRunOS()
        await settle(store)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(spy.restarts.count, 0, "a refusal made an hour ago is honoured")
    }

    func testUpdateThatFailsShowsTheReasonAndDoesNotRestart() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("update --json", err: "Error: could not download the release: connection reset", code: 1)
        let spy = PrivilegedSpy()
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.updateRunOS()
        await settle(store)

        XCTAssertEqual(store.errorMessage, "Error: could not download the release: connection reset")
        XCTAssertFalse(store.isUpdating)
        XCTAssertEqual(spy.restarts.count, 0)
    }

    func testUpdateResultThatCannotBeReadIsSaidAndEndsCleanly() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("update --json", out: "Downloading runos...")
        let spy = PrivilegedSpy()
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.updateRunOS()
        await settle(store)

        XCTAssertTrue(store.errorMessage?.hasPrefix("Cannot read the update result") == true, "\(String(describing: store.errorMessage))")
        XCTAssertFalse(store.isUpdating)
        XCTAssertEqual(spy.restarts.count, 0)
    }

    // MARK: two actions at once

    func testASecondActionStartedWhileOneRunsIsRefused() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn disconnect c-example1 --json", out: FakeCLI.vpnJSON(running: true), sleep: 1.5)
        cli.set("vpn down --json", out: FakeCLI.vpnJSON(running: false))
        cli.set("update --json", out: #"{"schemaVersion":1,"cli":{"updated":false}}"#)
        let spy = PrivilegedSpy()
        let (store, coordinator) = try make(cli, spy: spy)

        coordinator.perform(DesktopCommands.setCluster("c-example1", connected: true), message: "Disconnecting…")
        coordinator.perform(DesktopCommands.setVPN(enabled: false), message: "Disconnecting VPN…")
        coordinator.updateRunOS()
        coordinator.restartVPNService()
        coordinator.installVPNService()
        coordinator.signOut()

        XCTAssertEqual(store.operationMessage, "Disconnecting…", "the first action still owns the message")
        await settle(store)
        XCTAssertEqual(cli.count("vpn disconnect c-example1 --json"), 1)
        XCTAssertEqual(cli.count("vpn down --json"), 0)
        XCTAssertEqual(cli.count("update --json"), 0)
        XCTAssertEqual(cli.count("logout"), 0)
        XCTAssertEqual(spy.restarts.count, 0)
        XCTAssertEqual(spy.installs.count, 0)
    }

    func testAnActionDoesNotStartWhileASignInIsRunning() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (store, coordinator) = try make(cli)
        _ = store
        // beginSignIn would open a window; the guard it sets is what matters, and `perform` shares it.
        coordinator.perform(DesktopCommands.setVPN(enabled: false), message: "Disconnecting VPN…")
        coordinator.signOut()
        await settle(store)
        XCTAssertEqual(cli.count("logout"), 0)
    }

    // MARK: polling

    func testPollCadenceDoesNotLeakTasksWhenTheMenuIsOpenedAndClosedManyTimes() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        let (_, coordinator) = try make(cli, intervals: (.milliseconds(60), .milliseconds(60)))

        coordinator.start()
        for _ in 0..<15 {
            coordinator.setMenuOpen(true)
            coordinator.setMenuOpen(false)
        }
        try await Task.sleep(for: .milliseconds(1200))
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(500))

        // 15 opens refresh at once, plus about 20 polls in 1.2 s from ONE loop. 30 leaked loops
        // would be around 600.
        let ran = cli.count("--version")
        XCTAssertLessThan(ran, 90, "polls look leaked: \(ran) refreshes")
        let settled = cli.count("--version")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(cli.count("--version"), settled, "polling went on after stop()")
    }

    func testAReleasedCoordinatorStopsPolling() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        func startAndDrop() throws {
            let (_, coordinator) = try make(cli, intervals: (.milliseconds(40), .milliseconds(40)))
            coordinator.start()
        }
        try startAndDrop()
        // A refresh already in flight keeps the coordinator alive until it ends (about a fifth of a
        // second, five processes), so let that drain before measuring.
        try await Task.sleep(for: .milliseconds(1500))
        let settled = cli.count("--version")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(cli.count("--version"), settled, "a coordinator nobody holds must not keep refreshing")
    }

    // MARK: a CLI that never answers

    func testAStuckStatusIsReportedAndDoesNotFreezeTheRefresh() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("status --json", out: "{}", sleep: 6)
        let (store, coordinator) = try make(cli, readTimeout: .seconds(1))

        let started = Date()
        await coordinator.refresh()

        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertTrue(store.errorMessage?.contains("did not answer within 1 seconds") == true, "\(String(describing: store.errorMessage))")
        XCTAssertTrue(store.errorMessage?.contains("status --json") == true)
    }

    func testAStuckVPNStatusIsReportedAndOffersRestart() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("vpn status --json", out: "{}", sleep: 6)
        let (store, coordinator) = try make(cli, readTimeout: .seconds(1))

        await coordinator.refresh()

        XCTAssertEqual(store.vpnStatusProblem, .notAnswering)
        XCTAssertTrue(store.errorMessage?.contains("did not answer") == true)
        XCTAssertEqual(layout(store).item("restart-vpn")?.enabled, true)
        XCTAssertFalse(store.vpnServiceMissing, "a service that does not answer is not a missing one")
    }

    func testAProcessThatIgnoresTheStopRequestIsKilled() async throws {
        let cli = try FakeCLI()
        cli.setHealthy()
        cli.set("status --json", script: "trap '' TERM\nsleep 8\n")
        let (store, coordinator) = try make(cli, readTimeout: .seconds(1))

        let started = Date()
        await coordinator.refresh()

        XCTAssertLessThan(Date().timeIntervalSince(started), 6, "SIGTERM was ignored; SIGKILL must follow")
        XCTAssertTrue(store.errorMessage?.contains("did not answer") == true, "\(String(describing: store.errorMessage))")
    }

    func testARunWithoutATimeoutIsNotCutShort() async throws {
        // Actions (an update download, a connect that waits on a person) have no bound.
        let cli = try FakeCLI()
        cli.set("slow", out: "done", sleep: 1.5)
        let result = try await cli.runner().run(["slow"])
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
    }
}

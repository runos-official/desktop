import Combine
import Foundation
import XCTest
@testable import RunOSDesktop

final class CLIRunnerTests: XCTestCase {
    func testRunnerUsesConfiguredExecutableAndPreservesError() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "fake-runos")
        try "#!/bin/sh\necho 'exact CLI error' >&2\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = try CLIRunner(executableURL: executable)

        do {
            _ = try await runner.run(["status", "--json"])
            XCTFail("Expected the fake CLI to fail")
        } catch let error as CLIExecutionError {
            XCTAssertEqual(error.exitCode, 7)
            XCTAssertEqual(error.message, "exact CLI error")
        }
    }

    func testRunnerRejectsRelativeExecutable() {
        XCTAssertThrowsError(try CLIRunner(executableURL: URL(filePath: "runos", relativeTo: URL(filePath: "/tmp"))))
    }

    func testRunnerCapturesOutputLargerThanAPipeBuffer() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "fake-runos")
        let script = """
        #!/bin/sh
        index=0
        while [ "$index" -lt 8192 ]; do
          printf '0123456789abcdef'
          index=$((index + 1))
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = try CLIRunner(executableURL: executable)

        let result = try await runner.run([])

        XCTAssertEqual(result.stdout.count, 131_072)
    }

    func testRunnerCancellationTerminatesProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "fake-runos")
        try "#!/bin/sh\nexec sleep 3\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runner = try CLIRunner(executableURL: executable)
        let task = Task { try await runner.run(["account", "add", "--json"]) }

        try await Task.sleep(for: .milliseconds(100))
        let cancellationStarted = Date()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CLI execution to be cancelled")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancellationStarted), 1)
        }
    }

    @MainActor
    func testLiveDevelopmentCLIWhenConfigured() async throws {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/runos").path
        let path = ProcessInfo.processInfo.environment["RUNOS_LIVE_CLI"] ?? defaultPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Install the development CLI or set RUNOS_LIVE_CLI.")
        }
        let store = StateStore()
        let runner = try CLIRunner(executableURL: URL(filePath: path))
        /*
         SKIP UNLESS THE BINARY IS ACTUALLY A DEVELOPMENT BUILD.

         The guard above only asks whether a CLI is installed, then asserts `cliDevelopment`. On any
         machine holding a RELEASED CLI, which is every machine that has run `runos update`, this
         test failed on a fact about the installed binary rather than about the app. It blocked the
         release gate on 2026-08-25 with the CLI at 1.16.0. The name says "when configured", so
         being configured has to include being the kind of build the assertions describe.
        */
        let version = try await runner.run(["--version"])
        let versionText = String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard VersionComparator.compatibility(versionText, minimum: "1.15.0") == .development else {
            throw XCTSkip("The CLI at \(path) is '\(versionText)', not a development build. Set RUNOS_LIVE_CLI to one.")
        }
        let coordinator = RefreshCoordinator(store: store, runner: runner)

        await coordinator.refresh()

        XCTAssertTrue(store.cliDevelopment)
        XCTAssertFalse(store.cliOutdated)
        XCTAssertNil(store.errorMessage)
        XCTAssertNotNil(store.activeAccountId)
    }

    @MainActor
    func testCoordinatorAcceptsCapableDevelopmentCLI() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "account list --json": #"{"schemaVersion":1,"accounts":[]}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertTrue(store.cliDevelopment)
        XCTAssertFalse(store.cliOutdated)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.activeAccountId, "acct")
    }

    @MainActor
    func testCoordinatorPreservesDevelopmentCapabilityError() async throws {
        // `status --json` is deliberately absent, so the fake CLI refuses it. It used to be
        // `account list`, which the coordinator no longer runs at all now that the account
        // submenu is gone; the subject of the test is unchanged, only the command it fails on.
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        ], missingMessage: "status is unavailable")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertEqual(store.errorMessage, "status is unavailable")
    }

    @MainActor
    func testUnchangedRefreshDoesNotRepublishMenuState() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "account list --json": #"{"schemaVersion":1,"accounts":[]}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))
        await coordinator.refresh()
        var notificationCount = 0
        let observation = coordinator.objectWillChange.sink {
            notificationCount += 1
        }

        await coordinator.refresh()

        XCTAssertEqual(notificationCount, 0)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testCoordinatorCancelsCancellableAction() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "account list --json": #"{"schemaVersion":1,"accounts":[]}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#,
            "account add --json": "__WAIT__"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        coordinator.perform(
            ["account", "add", "--json"],
            message: "Waiting for browser authentication…",
            cancellable: true
        )
        XCTAssertTrue(store.canCancelOperation)
        coordinator.cancelOperation()
        for _ in 0..<100 where store.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.canCancelOperation)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testCoordinatorCancelsVPNBrowserAuthentication() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "account list --json": #"{"schemaVersion":1,"accounts":[]}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":true},"clusters":[]}"#,
            "vpn up --json --no-browser": "__WAIT__"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        coordinator.perform(
            DesktopCommands.setVPN(enabled: true),
            message: "Connecting VPN…",
            cancellable: true,
            cancelLabel: "Cancel Connection",
            cancellingMessage: "Cancelling connection…"
        )

        XCTAssertEqual(store.operationMessage, "Connecting VPN…")
        XCTAssertEqual(store.cancelOperationLabel, "Cancel Connection")
        coordinator.cancelOperation()
        for _ in 0..<100 where store.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.canCancelOperation)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testCoordinatorKeepsActivityDuringFinalRefresh() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let executable = try makeFakeCLI(commands: [
            "vpn up --json --no-browser": "{}",
            "--version": "__DELAY__dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "account list --json": #"{"schemaVersion":1,"accounts":[]}"#,
            // A genuinely working cluster, not just a tunnel that is up: the connected icon now
            // requires a cluster that is connected AND reachable. This test is about activity
            // during the final refresh, so the fixture is corrected rather than the assertion.
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#
        ], delayMarker: marker)
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: marker)
        }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        coordinator.perform(DesktopCommands.setVPN(enabled: true), message: "Connecting VPN…")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(store.operationMessage, "Connecting VPN…")

        for _ in 0..<200 where store.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.menuBarState, .connected)
    }

    /*
     THE APP NEVER MOVES THE TUNNEL ONTO ANOTHER ACCOUNT BY ITSELF (FPL26 D3).

     It used to. A `vpnAccountMismatch` made it run `vpn up --non-interactive` to follow the CLI,
     and two separate reports came out of that. "even though i don't have the connect at startup
     option selected, i seem to be connected", because `vpn up` brings the tunnel UP. And a switch
     that appeared to work but routed nothing, because the device key and the device id are both
     account-scoped and the connect path reused the previous account's.

     The rule now is that the tunnel never outlives the identity that opened it. The CLI drops it
     when the identity changes, and the person connects the new account deliberately. So a mismatch
     is read, and nothing is run.
    */
    @MainActor
    func testAMismatchedAccountIsNeverConnectedAutomatically() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "noauto-\(UUID().uuidString)")
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"abcde","vpnAccountId":"fghij","vpnAccountMismatch":true}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#,
            "vpn up --non-interactive --json": "__COUNT__"
        ], countMarker: marker)
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: marker)
        }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()
        await coordinator.refresh()

        let runs = (try? String(contentsOf: marker, encoding: .utf8))?.filter { $0 == "x" }.count ?? 0
        XCTAssertEqual(runs, 0, "a mismatched account must never be connected without being asked for")
        // And it is not turned into an error either. The person is signed in; the tunnel is simply
        // on the account it was opened on.
        XCTAssertNil(store.errorMessage)
    }

    /*
     A SIGNED-IN CLI IS WHAT MAKES THE VPN USABLE, and nothing else (FPL26 D1).

     This app used to have no concept of a CLI sign-in at all: Sign In ran `vpn up`, Sign Out ran
     `vpn down`, so "signed in" meant "has a VPN session". A machine could report
     `"authenticated": false` beside `"vpnRunning": true` from one invocation, and the app drew the
     second and never the first.
    */
    @MainActor
    func testASignedOutCLIIsSignedOutHoweverTheTunnelLooks() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":false,"authError":"Your session has ended. Run 'runos login' to sign in again.","authErrorKind":"rejected"}"#,
            // The tunnel is UP, on an account the CLI is no longer signed in to.
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertFalse(store.signedIn, "a running tunnel is not a sign-in")
        XCTAssertTrue(store.signInRequired)
        XCTAssertEqual(store.vpnMenuMode, .signedOut, "the VPN cannot be usable without an identity")
        XCTAssertFalse(store.vpnControlsUsable)
    }

    /*
     FCR160. A ten second timeout reaching Google's token endpoint is not a sign-out.

     `authenticated: false` covers both a refusal and a request that never completed. Treating them
     the same put a Sign In button and a tinted menu bar in front of someone whose session was
     perfectly valid, and rendered the raw Go error, request URL and API key included, in the menu.
    */
    @MainActor
    func testAnUnreachableTokenServiceIsNotASignOut() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":false,"authError":"Could not reach the sign-in service. Check your connection; your sign-in is unaffected.","authErrorKind":"network"}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"a1b","name":"lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertFalse(store.signInRequired, "a network blip must not ask anybody to sign in")
        XCTAssertEqual(store.menuBarState, .attention, "but it is still worth showing, so it is not .connected")
        // The sentence shown carries no URL and no key. That is the CLI's job, and this asserts the
        // app passes through what the CLI wrote rather than inventing wording of its own.
        XCTAssertEqual(store.errorMessage, "Could not reach the sign-in service. Check your connection; your sign-in is unaffected.")
    }

    /*
     THE WIRING, not just the decision.

     `AutoConnect.shouldConnect` has a table of its own, and it would still pass if nothing ever
     called it. That exact gap was found earlier the same day on the CLI side: the pure functions
     were green while the call sites had been reverted. So this drives real refreshes and counts
     what the CLI was actually asked to run.

     The sign-in has to change in the CLI's OWN answer. The coordinator remembers the previous
     sign-in state itself, so writing to the store cannot produce the transition.
    */
    @MainActor
    func testASignInCompletingConnectsTheVPNWhenAutoConnectIsOn() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "auto-\(UUID().uuidString)")
        let answers = FileManager.default.temporaryDirectory.appending(path: "status-\(UUID().uuidString)")
        try signedOut.write(to: answers, atomically: true, encoding: .utf8)
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": "__FILE__",
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#,
            "vpn up --non-interactive --json": "__COUNT__"
        ], countMarker: marker, answerFile: answers)
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: answers)
        }
        let coordinator = RefreshCoordinator(
            store: StateStore(),
            runner: try CLIRunner(executableURL: executable),
            autoConnect: StartupConnectController(defaults: enabledAutoConnectDefaults())
        )

        // Signed out. Nothing to connect with, and nothing must be attempted.
        await coordinator.refresh()
        XCTAssertEqual(countRuns(marker), 0, "there is no identity yet")

        // The sign-in completes. THIS is the moment the setting exists for, and the moment the old
        // code missed: it only ever tried once, in the app's init.
        try signedIn.write(to: answers, atomically: true, encoding: .utf8)
        await coordinator.refresh()
        for _ in 0..<200 where countRuns(marker) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(countRuns(marker), 1, "a completed sign-in must connect")

        // And it must not keep doing it on every poll thereafter.
        await coordinator.refresh()
        await coordinator.refresh()
        XCTAssertEqual(countRuns(marker), 1, "still signed in is not a new sign-in")
    }

    /// Off is off, however the sign-in state moves.
    @MainActor
    func testASignInDoesNotConnectWhenAutoConnectIsOff() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "noauto-\(UUID().uuidString)")
        let answers = FileManager.default.temporaryDirectory.appending(path: "status-\(UUID().uuidString)")
        try signedOut.write(to: answers, atomically: true, encoding: .utf8)
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": "__FILE__",
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#,
            "vpn up --non-interactive --json": "__COUNT__"
        ], countMarker: marker, answerFile: answers)
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: answers)
        }
        let coordinator = RefreshCoordinator(
            store: StateStore(),
            runner: try CLIRunner(executableURL: executable),
            autoConnect: StartupConnectController(defaults: disabledAutoConnectDefaults())
        )

        await coordinator.refresh()
        try signedIn.write(to: answers, atomically: true, encoding: .utf8)
        await coordinator.refresh()

        XCTAssertEqual(countRuns(marker), 0)
    }

    private var signedOut: String {
        #"{"schemaVersion":1,"authenticated":false,"authError":"signed out","authErrorKind":"rejected"}"#
    }

    private var signedIn: String {
        #"{"schemaVersion":1,"authenticated":true,"accountId":"abcde"}"#
    }

    private func disabledAutoConnectDefaults() -> UserDefaults {
        UserDefaults(suiteName: "autoconnect-off-\(UUID().uuidString)")!
    }

    /// A UserDefaults of its own, so a test never reads or writes the developer's real preference.
    private func enabledAutoConnectDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "autoconnect-test-\(UUID().uuidString)")!
        suite.set(true, forKey: "connectVPNAtStartup")
        return suite
    }

    private func countRuns(_ marker: URL) -> Int {
        (try? String(contentsOf: marker, encoding: .utf8))?.filter { $0 == "x" }.count ?? 0
    }

    /*
     A FAILED ACTION HAS TO LEAVE ITS SENTENCE ON SCREEN.

     `perform` writes the failure into `store.errorMessage`, then calls `refresh`, whose last act is
     `update(\.errorMessage, to: store.signInRequired ? nil : status.authError)`. For a healthy
     sign-in `authError` is nil, so that line writes nil over the failure 21 lines later in the same
     synchronous pass. SwiftUI never renders it.

     `store.errorMessage` is the menu's ONLY failure surface, so the click reads as dead: the person
     presses Disconnect, the tunnel stays up, and the app says nothing at all. Every command routed
     through `perform` is affected, and so are Install VPN Service and Update RunOS, which have the
     same set-then-refresh shape.

     The comment above that line names this exact swallowing as the defect reported 2026-08-25 and
     says it is fixed. It was fixed at the point where the error is raised, and reintroduced by the
     next statement.
    */
    @MainActor
    func testAFailedActionKeepsItsErrorOnScreen() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#
        ], missingMessage: "the RunOS VPN service is not responding")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        coordinator.perform(["vpn", "down", "--json"], message: "Disconnecting…")
        for _ in 0..<200 where store.isBusy {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(store.errorMessage, "the RunOS VPN service is not responding",
                       "a command that failed must still be saying so once the spinner stops")
    }

    /*
     The same overwrite, reached through the refresh itself rather than through an action.

     A `vpn status` that fails for any reason OTHER than the service being missing is classified as
     an error and assigned. Twenty-one lines later the same pass nils it. The menu then draws an
     ordinary VPN submenu offering Connect, and never says the daemon refused to answer.
    */
    @MainActor
    func testAVPNStatusFailureThatIsNotAMissingServiceReachesTheMenu() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#
        ], missingMessage: "the VPN daemon is not answering")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertFalse(store.vpnServiceMissing, "the service is installed; it refused the question")
        XCTAssertEqual(store.errorMessage, "the VPN daemon is not answering")
    }

    /*
     AN OUTDATED CLI MUST NOT DISABLE THE ONE CONTROL THAT FIXES IT.

     `refresh` returns early when the CLI is too old or its version cannot be read, before
     `checkForUpdatesIfDue` ever runs. `updateVerdictKnown` therefore stays nil, which
     `updateActionEnabled` reads as "nothing asked yet" and renders disabled.

     So the machine whose CLI is out of date is exactly the machine where Update RunOS cannot be
     clicked. The app tells the person to run `runos update` in a terminal, which is the thing the
     menu item exists to save them from, and the three-state verdict was introduced precisely so
     that "no verdict" would still leave the control usable.
    */
    @MainActor
    func testAnOutdatedCLIStillLetsYouClickUpdate() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "1.0.0",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertTrue(store.cliOutdated)
        XCTAssertTrue(store.updateActionEnabled,
                      "the machine with the outdated CLI is the one that needs this control most")
    }

    // The same, for a version string the app cannot parse at all. It is no more evidence that an
    // update is absent than an outdated one is.
    @MainActor
    func testAnUnreadableCLIVersionStillLetsYouClickUpdate() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "not-a-version",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertTrue(store.updateActionEnabled)
    }

    /*
     CANCELLING IS NOT A FAULT, AND ITS INTERNAL NAME IS NOT A SENTENCE.

     The poll refresh runs in a Task that is cancelled on every teardown and on every new schedule.
     A cancellation surfaces as Swift's own `CancellationError`, whose `localizedDescription` is the
     untranslated string "The operation couldn\u{2019}t be completed. (Swift.CancellationError error 1.)".
     The outer catch assigns it verbatim, which puts that in the menu and turns the menu bar icon to
     the attention state because `menuBarState` reads any errorMessage as trouble.
    */
    @MainActor
    func testACancelledRefreshSaysNothingAtAll() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": "__WAIT__"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        let task = Task { await coordinator.refresh() }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()
        _ = await task.value

        XCTAssertNil(store.errorMessage, "a cancellation is the app tidying up, not something to report")
        XCTAssertNotEqual(store.menuBarState, .attention)
    }

    /*
     A CONNECT THAT FAILS BEFORE A DEVICE CODE MUST STILL SAY WHY.

     `.confirm` defers its window until a device code arrives, because a connect that needs no
     confirmation was opening and withdrawing a modal on the common path. But `runos vpn up` can
     exit nonzero BEFORE any device code: conductor refuses the enrolment, the session mint fails,
     the daemon is not running, the network is down. No device code means no window, ever.

     `finish` then wrote the CLI's own sentence into `phase`, which is rendered only inside the
     panel nobody saw, and `onEnded` carried nothing, so the coordinator cleared its progress
     message and wrote no error. The person watched "Connecting VPN…" appear and vanish, the VPN
     stayed down, and nothing anywhere said why.

     That is the same shape as the reported defect the deferred window was built to avoid, arriving
     on the failure path. The stderr capture added for exactly this reason captured the remedy and
     then dropped it.
    */
    @MainActor
    func testAConnectThatFailsBeforeADeviceCodeStillReportsWhy() async throws {
        let executable = try makeFakeCLI(
            commands: ["--version": "dev-2026-08-17T11:42:49Z"],
            missingMessage: "device enrolment was refused: this device is not registered"
        )
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = try CLIRunner(executableURL: executable)
        let model = SignInRunner(runner: runner, purpose: .confirm, onFinished: {})
        var reported: String??
        model.onEnded = { reported = $0 }

        model.start()
        for _ in 0..<200 where reported == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(reported ?? nil, "device enrolment was refused: this device is not registered",
                       "a run that never opened a window must still hand its failure back")
    }

    // A cancellation is not a failure, so it must hand back nothing to report. Closing the window
    // is the ordinary way somebody backs out, and an error banner for it would be wrong.
    @MainActor
    func testCancellingASignInReportsNoFailure() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "vpn up --json --no-browser": "__WAIT__"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = try CLIRunner(executableURL: executable)
        let model = SignInRunner(runner: runner, purpose: .confirm, onFinished: {})
        var reported: String??
        model.onEnded = { reported = $0 }

        model.start()
        try await Task.sleep(for: .milliseconds(120))
        model.cancel()

        XCTAssertNotNil(reported, "onEnded must fire on a cancellation")
        XCTAssertNil(reported ?? nil, "a cancellation has nothing to report")
    }

    /*
     STARTING A SECOND SIGN-IN MUST STOP THE FIRST.

     `SignInRunner` routes every streamed line through one static `current`, on the stated
     assumption that "only one sign-in window exists at a time". Nothing enforced that for RUNS.
     `beginSignIn` guards on `actionRunning` and never assigns it, so the Sign In button stayed
     live for the whole login, and the panel is a non-modal NSPanel so the menu bar stayed
     clickable. The CLI runs with --no-browser, so nothing opens by itself and somebody who thinks
     the click did nothing clicks again.

     A second `start()` reassigned the static router without stopping the first process, so two
     `runos login` runs delivered into one model. Concrete damage: the first run's device code
     overwrites the one the person is meant to compare against the browser page, which defeats the
     only anti-spoofing check the window exists for; and its timeout, five minutes later, flips a
     still-valid window to a failure.
    */
    @MainActor
    func testASecondSignInStopsTheFirst() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "login --json --no-browser": "__WAIT__"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let runner = try CLIRunner(executableURL: executable)
        let first = SignInRunner(runner: runner, purpose: .signIn, onFinished: {})
        first.start()
        try await Task.sleep(for: .milliseconds(120))

        let second = SignInRunner(runner: runner, purpose: .signIn, onFinished: {})
        second.start()

        XCTAssertEqual(first.phase, .failed("Sign in cancelled."),
                       "the run that lost the stream must be stopped, not left polling unattended")
        XCTAssertEqual(second.phase, .starting)
        second.cancel()
    }

    private func makeFakeCLI(
        commands: [String: String],
        missingMessage: String = "unexpected command",
        delayMarker: URL? = nil,
        countMarker: URL? = nil,
        answerFile: URL? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "fake-runos")
        var script = "#!/bin/sh\ncase \"$*\" in\n"
        for (arguments, output) in commands {
            if output == "__COUNT__", let countMarker {
                // Appends one mark per invocation, so a test can count how often it ran.
                let escapedCounter = countMarker.path.replacingOccurrences(of: "'", with: "'\\''")
                script += "  '\(arguments)') printf 'x' >> '\(escapedCounter)'; printf '{}\\n' ;;\n"
            } else if output == "__FILE__", let answerFile {
                // The answer comes from a file the test rewrites between polls. Some state the
                // coordinator tracks ITSELF, such as a sign-in completing, can only be reached by
                // the CLI genuinely changing its answer; poking the store cannot reproduce it.
                let escapedFile = answerFile.path.replacingOccurrences(of: "'", with: "'\\''")
                script += "  '\(arguments)') cat '\(escapedFile)' ;;\n"
            } else if output == "__WAIT__" {
                script += "  '\(arguments)') exec sleep 3 ;;\n"
            } else if output.hasPrefix("__DELAY__"), let delayMarker {
                let delayedOutput = String(output.dropFirst("__DELAY__".count))
                    .replacingOccurrences(of: "'", with: "'\\''")
                let escapedMarker = delayMarker.path.replacingOccurrences(of: "'", with: "'\\''")
                script += "  '\(arguments)') : > '\(escapedMarker)'; sleep 1; printf '%s\\n' '\(delayedOutput)' ;;\n"
            } else {
                let escapedOutput = output.replacingOccurrences(of: "'", with: "'\\''")
                script += "  '\(arguments)') printf '%s\\n' '\(escapedOutput)' ;;\n"
            }
        }
        let escapedMessage = missingMessage.replacingOccurrences(of: "'", with: "'\\''")
        script += "  *) printf '%s\\n' '\(escapedMessage)' >&2; exit 7 ;;\nesac\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

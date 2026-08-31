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

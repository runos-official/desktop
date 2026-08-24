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
            "vpn up --json": "__WAIT__"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        coordinator.setVPN(enabled: true)

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
            "vpn up --json": "{}",
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

        coordinator.setVPN(enabled: true)
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
     The VPN follows the account you are on, without asking.

     Reported as: "i still get this garbage which again makes no sense". The app was telling a
     person that the CLI and the VPN were signed in to different accounts and asking them to
     reconcile it with a button. That exposes two account states they never knew existed, to ask
     them to fix something the app can fix itself.

     A mismatch is now something the app resolves. It runs `vpn up --non-interactive`, which is
     silent when the sign-in is recent enough, and the person sees nothing at all.
    */
    @MainActor
    func testTheAppSwitchesTheVPNAccountItselfInsteadOfAsking() async throws {
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"abcde","vpnAccountId":"fghij","vpnAccountMismatch":true}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#,
            "vpn up --non-interactive --json": "{}"
        ])
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        // It ran, so nothing is put in front of the person: no sign-in prompt, no error.
        XCTAssertFalse(store.vpnSignInRequired, "a switch it could perform must not be announced")
        XCTAssertNil(store.errorMessage)
    }

    /*
     Reported after the account-follow shipped: "even though i don't have the connect at startup
     option selected, i seem to be connected".

     `vpn up` signs in AND brings the tunnel up, so following the account turned the VPN ON for a
     person who had not asked for it. Connecting is a decision they make, through the Connect
     button or the startup preference, and never a side effect of the app tidying its own state.

     With the VPN down there is nothing to follow anyway: a tunnel that is not running is not
     showing anybody the wrong clusters.
    */
    @MainActor
    func testFollowingTheAccountNeverTurnsTheVPNOn() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "noup-\(UUID().uuidString)")
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"abcde","vpnAccountId":"fghij","vpnAccountMismatch":true}"#,
            // The tunnel is DOWN.
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#,
            "vpn up --non-interactive --json": "__COUNT__"
        ], countMarker: marker)
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: marker)
        }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        let runs = (try? String(contentsOf: marker, encoding: .utf8))?.filter { $0 == "x" }.count ?? 0
        XCTAssertEqual(runs, 0, "a VPN that is down must be left down")
        XCTAssertFalse(store.vpnSignInRequired, "and nothing is asked for either")
    }

    /*
     The one case the app genuinely cannot resolve: Conductor wants a fresh sign-in, and an
     unattended switch may not open a browser. Only then is the person asked, and what they are
     asked for is a sign-in, never to reconcile two accounts.
    */
    @MainActor
    func testASignInThatCannotBePerformedIsTheOnlyThingAsked() async throws {
        // `vpn up --non-interactive --json` is absent, so the fake refuses it.
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"abcde","vpnAccountId":"fghij","vpnAccountMismatch":true}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[]}"#
        ], missingMessage: "the VPN needs a fresh sign-in and this run may not open a browser")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertTrue(store.vpnSignInRequired, "a switch it could not perform must be asked for")
        // The failure is not an error banner: it is a thing to do, shown as a sign-in prompt.
        XCTAssertNil(store.errorMessage)
    }

    /*
     The attempt happens once per account, not on every poll.

     Without this, a person whose sign-in has genuinely expired would have the app run `vpn up`
     against Conductor every few seconds for as long as the menu bar is open.
    */
    @MainActor
    func testTheSwitchIsNotRetriedOnEveryPoll() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "switch-\(UUID().uuidString)")
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
        await coordinator.refresh()

        let runs = (try? String(contentsOf: marker, encoding: .utf8))?.filter { $0 == "x" }.count ?? 0
        XCTAssertEqual(runs, 1, "the switch must be attempted once for the account, not every poll")
    }

    private func makeFakeCLI(
        commands: [String: String],
        missingMessage: String = "unexpected command",
        delayMarker: URL? = nil,
        countMarker: URL? = nil
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

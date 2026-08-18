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
            "vpn status --json": #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false},"clusters":[{"cid":"g4v","name":"lab","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]}"#
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

    private func makeFakeCLI(
        commands: [String: String],
        missingMessage: String = "unexpected command",
        delayMarker: URL? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "fake-runos")
        var script = "#!/bin/sh\ncase \"$*\" in\n"
        for (arguments, output) in commands {
            if output == "__WAIT__" {
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

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
        let executable = try makeFakeCLI(commands: [
            "--version": "dev-2026-08-17T11:42:49Z",
            "status --json": #"{"schemaVersion":1,"authenticated":true,"accountId":"acct"}"#,
            "vpn status --json": #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        ], missingMessage: "account list is unavailable")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertEqual(store.errorMessage, "account list is unavailable")
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

    private func makeFakeCLI(commands: [String: String], missingMessage: String = "unexpected command") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "fake-runos")
        var script = "#!/bin/sh\ncase \"$*\" in\n"
        for (arguments, output) in commands {
            if output == "__WAIT__" {
                script += "  '\(arguments)') exec sleep 3 ;;\n"
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

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
}

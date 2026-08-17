import Foundation

struct CLIResult: Sendable {
    let stdout: Data
    let stderr: String
    let exitCode: Int32

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder.runOS.decode(type, from: stdout)
    }
}

struct CLIExecutionError: LocalizedError, Sendable {
    let exitCode: Int32
    let message: String

    var errorDescription: String? { message }
}

actor CLIRunner {
    let executableURL: URL

    init(executableURL: URL) throws {
        guard executableURL.path.hasPrefix("/") else {
            throw CLIExecutionError(exitCode: -1, message: "The RunOS CLI path must be absolute.")
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CLIExecutionError(exitCode: -1, message: "The RunOS CLI is missing at \(executableURL.path). Run 'runos update'.")
        }
        self.executableURL = executableURL
    }

    func run(_ arguments: [String]) async throws -> CLIResult {
        let process = Process()
        let fileManager = FileManager.default
        let executionDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(
            at: executionDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: executionDirectory) }
        let outputURL = executionDirectory.appending(path: "stdout")
        let errorURL = executionDirectory.appending(path: "stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fileManager.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw CLIExecutionError(exitCode: -1, message: "RunOS Desktop cannot create CLI output files.")
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try process.run()
                    if Task.isCancelled {
                        process.terminate()
                    }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        try Task.checkCancellation()
        try outputHandle.close()
        try errorHandle.close()

        let stdout = try Data(contentsOf: outputURL)
        let stderrData = try Data(contentsOf: errorURL)
        let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CLIResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        if result.exitCode != 0 {
            let stdoutMessage = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIExecutionError(exitCode: result.exitCode, message: stderr.isEmpty ? stdoutMessage : stderr)
        }
        return result
    }
}

enum CLIPathResolver {
    private struct Configuration: Decodable {
        let cliPath: String
    }

    static func resolve(fileManager: FileManager = .default) throws -> URL {
        let support = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/RunOS Desktop/config.json")
        if let data = try? Data(contentsOf: support),
           let configuration = try? JSONDecoder().decode(Configuration.self, from: data),
           configuration.cliPath.hasPrefix("/"),
           fileManager.isExecutableFile(atPath: configuration.cliPath) {
            return URL(filePath: configuration.cliPath)
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/runos",
            "/usr/local/bin/runos",
            "\(home)/.local/bin/runos"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        throw CLIExecutionError(
            exitCode: -1,
            message: "RunOS Desktop cannot find the RunOS CLI. Install or update the CLI, then run 'runos desktop install'."
        )
    }
}

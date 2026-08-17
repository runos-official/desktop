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

    func run(_ arguments: [String]) throws -> CLIResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
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

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

/// What a streamed run ended as. `errorOutput` is whatever the CLI put on stderr, kept so a failure
/// can be reported in the CLI's own words instead of a generic sentence.
struct CLIStreamResult: Sendable {
    let exitCode: Int32
    let errorOutput: String

    /*
     The one line worth showing a person.

     The CLI's convention is a final sentence carrying the remedy, sometimes after progress prose on
     the same stream. The LAST non-empty line is that sentence. Empty when the CLI said nothing,
     which is the only case a caller has to invent wording for.
    */
    var failureSentence: String? {
        errorOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
    }
}

/// Collects stderr off the pipe's delivery thread. A plain `var` captured by the handler would be a
/// data race; this keeps the append behind a lock so `Sendable` means what it says.
final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
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

    /*
     Run a process whose FAILURE is an expected answer, not an error.

     `run` throws on a nonzero exit and puts the whole of stdout in the message, which is right for
     the CLI: its exit codes mean something went wrong and its sentence is the one to show. It is
     wrong for a diagnostic probe. `ping` exits 2 when a host does not answer, which is the fact the
     Connection Status window is asking for, and throwing it turned a one-word verdict into four
     lines of raw ping output in the window (reported 2026-08-25).

     The caller gets the exit code and reads the outcome itself.
    */
    func probe(_ arguments: [String]) async throws -> CLIResult {
        try await execute(arguments)
    }

    func run(_ arguments: [String]) async throws -> CLIResult {
        let result = try await execute(arguments)
        if result.exitCode != 0 {
            let stdoutMessage = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIExecutionError(
                exitCode: result.exitCode,
                message: result.stderr.isEmpty ? stdoutMessage : result.stderr
            )
        }
        return result
    }

    /*
     Run the CLI and deliver its stdout LINE BY LINE as it arrives.

     `run` and `probe` both wait for the process to exit and then read a file, which is right for a
     command that produces one answer. The browser sign-in produces a conversation: a device id to
     check against the browser, a URL to fall back on, and a status that changes while a person
     watches. Waiting for exit would deliver all of that after it stopped mattering.

     Cancelling the task terminates the process, which is what the window's Cancel button is: there
     is no other way to stop a poll loop that is waiting on a person.
    */
    func stream(
        _ arguments: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLIStreamResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        /*
         KEPT SEPARATE, AND KEPT.

         Separate because the CLI writes prose to stderr during this flow ("This VPN session needs a
         fresh sign-in."), and mixing it into the line stream would hand the parser text that is not
         an event. But it used to be thrown at `nullDevice`, which meant every reason a sign-in could
         fail after the browser authorised was destroyed on the way out: the token exchange, the
         enrolment, the session mint. All of them reached the person as "Sign in did not complete."
         (reported 2026-08-26 and 2026-08-28).

         It is buffered rather than streamed because nobody reads it until the process has failed.
        */
        process.standardError = errors
        let collectedErrors = ErrorBuffer()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collectedErrors.append(data)
        }

        // Bytes arrive in whatever chunks the pipe gives, which is not lines. The remainder is held
        // until its newline turns up, so a JSON object split across two reads is not two broken ones.
        let pending = LineBuffer(onLine: onLine)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            pending.append(data)
        }

        try Task.checkCancellation()
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        pending.finish()
        return CLIStreamResult(exitCode: exitCode, errorOutput: collectedErrors.text())
    }

    private func execute(_ arguments: [String]) async throws -> CLIResult {
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
        return CLIResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
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

/*
 Splits a byte stream into lines, holding a partial line until its newline arrives.

 A pipe delivers whatever chunks it feels like, which is not lines. Without this a JSON object split
 across two reads becomes two unparseable fragments, and the one event that matters most, the device
 code, is the longest line and so the likeliest to be split.
*/
final class LineBuffer: @unchecked Sendable {
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var buffer = Data()

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        var complete: [String] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            complete.append(String(decoding: line, as: UTF8.self))
        }
        lock.unlock()
        complete.forEach(onLine)
    }

    /// Deliver whatever is left when the process exits without a trailing newline.
    func finish() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        guard !rest.isEmpty else { return }
        onLine(String(decoding: rest, as: UTF8.self))
    }
}

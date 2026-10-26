import Foundation
import XCTest
@testable import RunOSDesktop

/*
 A fake `runos` whose answers are files, so a test can change what the CLI says between two polls.

 Each command is a key (its arguments joined with spaces). `set` writes the answer for a key:
 stdout, stderr, exit code and an optional delay. Every call is appended to a log, so a test can
 count how often a command ran. A command nobody set exits 127 with "unexpected command", which
 is what a CLI that does not know a command does.

 Process execution stays in CLIRunner: this only builds the executable the runner is pointed at.
*/
final class FakeCLI: @unchecked Sendable {
    let directory: URL
    var executable: URL { directory.appending(path: "fake-runos") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "fake-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        D='\(directory.path)'
        K=$(printf '%s' "$*" | tr -c 'A-Za-z0-9' '_')
        printf '%s\\n' "$*" >> "$D/calls.log"
        if [ -f "$D/$K.sh" ]; then exec sh "$D/$K.sh"; fi
        if [ -f "$D/$K.sleep" ]; then sleep "$(cat "$D/$K.sleep")"; fi
        if [ -f "$D/$K.err" ]; then cat "$D/$K.err" >&2; fi
        if [ -f "$D/$K.out" ]; then cat "$D/$K.out"; fi
        if [ -f "$D/$K.code" ]; then exit "$(cat "$D/$K.code")"; fi
        if [ -f "$D/$K.out" ] || [ -f "$D/$K.err" ]; then exit 0; fi
        printf 'unexpected command\\n' >&2
        exit 127
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private func key(_ command: String) -> String {
        String(command.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "_" })
    }

    private func write(_ command: String, _ ext: String, _ text: String) {
        try? text.write(to: directory.appending(path: "\(key(command)).\(ext)"), atomically: true, encoding: .utf8)
    }

    private func remove(_ command: String, _ ext: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(key(command)).\(ext)"))
    }

    /// Replaces everything the fake says for `command`.
    func set(_ command: String, out: String? = nil, err: String? = nil, code: Int32? = nil, sleep: Double? = nil, script: String? = nil) {
        for ext in ["out", "err", "code", "sleep", "sh"] { remove(command, ext) }
        if let out { write(command, "out", out + "\n") }
        if let err { write(command, "err", err + "\n") }
        if let code { write(command, "code", "\(code)") }
        if let sleep { write(command, "sleep", "\(sleep)") }
        if let script { write(command, "sh", script) }
    }

    func setFixture(_ command: String, family: String, stem: String, code: Int32? = nil) throws {
        let data = try Fixtures.data(family, stem)
        set(command, out: String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\n")), code: code)
        // Fixtures with no content at all (an empty output) still need the command to exist.
        if data.isEmpty { try? Data().write(to: directory.appending(path: "\(key(command)).out")) }
    }

    var calls: [String] {
        ((try? String(contentsOf: directory.appending(path: "calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func count(_ command: String) -> Int { calls.filter { $0 == command }.count }

    func runner() throws -> CLIRunner { try CLIRunner(executableURL: executable) }

    // MARK: the usual answers

    static let version = "1.22.2"

    /// A healthy, signed-in machine with the tunnel up, the CLI and the service on the same build.
    func setHealthy() {
        set("--version", out: Self.version)
        set("status --json", out: #"{"schemaVersion":1,"authenticated":true,"accountId":"acct-example"}"#)
        set("user accounts --json", out: #"{"accounts":[]}"#)
        set("vpn status --json", out: Self.vpnJSON(running: true))
        set("update --check --json", out: #"{"schemaVersion":1,"cli":{"updateAvailable":false},"desktop":null}"#)
    }

    static func vpnJSON(running: Bool, version: String? = version, dns: String? = nil) -> String {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(20 * 3600))
        let versionPart = version.map { #","version":"\#($0)""# } ?? ""
        let dnsPart = dns.map { #","dns":\#($0)"# } ?? ""
        return #"{"schemaVersion":1,"running":\#(running),"session":{"present":true,"expiresAt":"\#(expires)","loginRequired":false},"clusters":[{"cid":"c-example1","name":"Example Cluster","connected":true,"reachable":true,"peerUp":true,"peeredWith":[]}]\#(versionPart)\#(dnsPart)}"#
    }
}

extension XCTestCase {
    /// Polls `condition` every 10 ms until it holds or `timeout` passes.
    @MainActor
    func waitUntil(_ timeout: TimeInterval = 10, _ message: String = "condition", _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let reached = condition()
        XCTAssertTrue(reached, "timed out waiting for \(message)")
    }

    /// A UserDefaults of its own, so a test never reads or writes the developer's real preference.
    @MainActor
    func makeAutoConnect(enabled: Bool = false) -> StartupConnectController {
        let defaults = UserDefaults(suiteName: "runos-desktop-test-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: "connectVPNAtStartup")
        return StartupConnectController(defaults: defaults)
    }
}

/// Records what a privileged action was asked to do and answers as the test says.
final class PrivilegedSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _restarts: [(cliPath: String, prompt: String)] = []
    private var _installs: [String] = []
    var restartResult: Result<String, Error> = .success("")
    var installResult: Result<String, Error> = .success("")

    var restarts: [(cliPath: String, prompt: String)] { lock.withLock { _restarts } }
    var installs: [String] { lock.withLock { _installs } }

    var service: PrivilegedService {
        PrivilegedService(
            install: { [self] path in
                lock.withLock { _installs.append(path) }
                return try installResult.get()
            },
            restart: { [self] path, prompt in
                lock.withLock { _restarts.append((path, prompt)) }
                return try restartResult.get()
            })
    }
}

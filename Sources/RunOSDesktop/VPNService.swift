import Foundation

/*
 Whether the RunOS VPN system service is installed, and how to install it.

 WHY THIS EXISTS. `runos desktop install` puts the app on disk and nothing else. The tunnel is
 carried by a separate root LaunchDaemon that only `sudo runos vpn install` creates, so "install
 the app, click Connect" was a broken path by construction. The CLI says so perfectly:

     Error: the RunOS VPN service is not running (/var/run/runos-vpn.sock).
     Run 'sudo runos vpn install' first.

 The app threw that sentence away in two places. `refresh` read VPN status with `try?`, so the
 failure became a nil status and no message at all; and the startup connect caught every error and
 reported "sign in required", which sends a person to a browser to fix a missing daemon. Reported
 2026-08-25: the app looked like it did nothing when Connect was clicked.
*/
enum VPNService {
    /// Where the daemon listens. Matches `SocketPath` in the CLI's `internal/vpn`.
    static let socketPath = "/var/run/runos-vpn.sock"

    /*
     Whether a CLI failure means the service is absent rather than anything the person did.

     Matched on the CLI's own words rather than an exit code, because the CLI exits 1 for every
     refusal and only the sentence separates them. Both halves are checked: the socket path is the
     stable part of the message, and the remedy names the command, so a reworded error still lands
     as long as one survives.
    */
    static func isMissing(_ error: Error) -> Bool {
        let text = (error as? CLIExecutionError)?.message ?? error.localizedDescription
        return text.contains(socketPath) || text.localizedCaseInsensitiveContains("vpn install")
    }

    /*
     Install the service, with the one administrator prompt it needs.

     osascript's `with administrator privileges` is used deliberately: it is the standard macOS
     authorization dialog, so the person is asked by the OS and names what is being installed,
     rather than the app inventing a password box of its own. The CLI path is quoted because a
     user's home directory can contain spaces.

     Returns the CLI's own output. Throws with the OS or CLI message on failure, including when the
     person cancels the prompt, which is a refusal to report and not a state to retry.
    */
    static func install(cliPath: String, userName: String = NSUserName()) async throws -> String {
        try await runPrivileged(
            installCommand(cliPath: cliPath, userName: userName),
            cancelled: "Installing the VPN service needs an administrator password. Nothing was changed.",
            failed: "The VPN service could not be installed.")
    }

    /*
     Restart the VPN service, so it runs the build the CLI was just updated to.

     The service runs the same binary `runos update` replaces, and launchd holds the old inode open,
     so an update leaves the daemon on the previous build. The CLI says so and deliberately does not
     act, because `runos update` has no administrator rights and escalating in the middle of an
     unrelated command would be a surprise.

     FROM THE MENU IT IS NOT A SURPRISE. The person clicked a thing and is watching it happen, which
     is exactly when a password prompt is expected. Cancelling is a refusal, not a fault: the menu
     keeps offering it.

     Brief: the tunnel drops while the service reloads and re-converges on its own within seconds.
    */
    static func restart(cliPath: String) async throws -> String {
        try await runPrivileged(
            restartCommand(cliPath: cliPath),
            cancelled: "Restarting the VPN service needs an administrator password. Nothing was changed.",
            failed: "The VPN service could not be restarted.")
    }

    private static func runPrivileged(_ command: String, cancelled: String, failed: String) async throws -> String {
        let script = "do shell script \"\(appleScriptQuoted(command))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIExecutionError(
                exitCode: process.terminationStatus,
                // -128 is osascript's code for "the person pressed Cancel", which is not a fault.
                message: message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled")
                    ? cancelled
                    : (message.isEmpty ? failed : message)
            )
        }
        return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /*
     The command run as root, and why it carries SUDO_USER.

     `runos vpn install` decides which group may open the control socket, so that the installing
     person reaches it WITHOUT sudo afterwards. It reads SUDO_USER to find who that person is, and
     falls back to the effective user's primary group when it is unset.

     osascript's `with administrator privileges` is not sudo. It runs the command as root directly,
     so SUDO_USER is absent, the fallback picks root's primary group, and the socket lands as
     `root:wheel`. An ordinary macOS account is in `staff` and `admin`, NOT `wheel`, so the daemon
     installs, starts, and is then unreachable by the very person who installed it: `vpn status`
     reports "the RunOS VPN service is not running" while the process is running fine.
     Measured 2026-08-25.

     Setting SUDO_USER gives the CLI the same fact `sudo` would have given it. It is set INSIDE the
     command rather than passed as an env var, because osascript does not forward the caller's
     environment.
    */
    static func installCommand(cliPath: String, userName: String) -> String {
        "SUDO_USER=\(shellQuoted(userName)) \(shellQuoted(cliPath)) vpn install"
    }

    /// `vpn restart` needs no SUDO_USER: it reloads the service in place and rewrites nothing that
    /// depends on who asked. See installCommand for why install does.
    static func restartCommand(cliPath: String) -> String {
        "\(shellQuoted(cliPath)) vpn restart"
    }

    /// Single-quote for /bin/sh, closing and reopening around any embedded quote.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for embedding inside an AppleScript string literal.
    static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

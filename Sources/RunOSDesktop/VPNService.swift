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

     MATCHED ON THE ONE SENTENCE THAT MEANS IT (FCR 1732): "the RunOS VPN service is not running
     (<socket path>). Run 'sudo runos vpn install' first." The socket path and the words "vpn
     install" were each enough before, and two other CLI errors carry them: the socket permission
     error ("The service IS running, so this is not an install problem") and the older-service error
     that offers `vpn install` as a fallback. Both made the menu offer Install for a service that
     was running. The CLI's wording is pinned in its desktop contract; a different failure of the
     service shows the CLI's own sentence, and the Restart VPN item is always there.
    */
    static func isMissing(_ error: Error) -> Bool {
        let text = (error as? CLIExecutionError)?.message ?? error.localizedDescription
        return text.localizedCaseInsensitiveContains(missingMarker)
    }

    /// The start of the CLI's "service is not installed or not running" sentence.
    static let missingMarker = "VPN service is not running ("

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
            prompt: installPrompt,
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
    static func restart(cliPath: String, prompt: String = VPNService.restartPrompt) async throws -> String {
        try await runPrivileged(
            restartCommand(cliPath: cliPath),
            prompt: prompt,
            cancelled: "Restarting the VPN service needs an administrator password. Nothing was changed.",
            failed: "The VPN service could not be restarted.")
    }

    /*
     Ask for the administrator password, and run one command as root.

     IN-PROCESS, VIA NSAppleScript. It used to spawn /usr/bin/osascript, and macOS attributes an
     authorisation request to the process that ASKED, so the dialog read "osascript wants to make
     changes" with no reason given. A generic scripting tool asking for administrator rights, with
     no explanation, is exactly the prompt a person should refuse. Running the script here makes
     this app the requester, so the dialog names it, and `with prompt` puts the reason above the
     password field.

     ON THE MAIN THREAD, and this COSTS SOMETHING. NSAppleScript is documented as main-thread-only,
     so the main actor is held here. `do shell script` returns the command's stdout, so it does not
     return until the command has EXITED: the app is unresponsive for the dialog AND for the whole
     run of `vpn install` or `vpn restart`, not merely while somebody types their password.

     That is a real regression against the previous shape, which ran the same script through a
     `Process` off the main actor and left the menu drawing throughout. It buys the thing that shape
     could not have: the dialog names this app and states its business, because macOS attributes an
     authorisation request to the process that asked, and there it was asking through
     /usr/bin/osascript.

     THERE IS NO CHEAP BOUND ON IT. AppleScript's `with timeout` does not apply to `do shell script`:
     MEASURED 2026-08-31, `with timeout of 2 seconds` around `do shell script "sleep 8"` returned
     successfully after 8.1 seconds. So a wedged CLI would hang the app, and nothing here prevents
     that. The two commands are short by construction (one writes a plist and bootstraps it, the
     other is a `launchctl kickstart`), which is the whole of why this trade is acceptable; neither
     has been timed under root.
    */
    private static func runPrivileged(
        _ command: String, prompt: String, cancelled: String, failed: String
    ) async throws -> String {
        let source = privilegedScript(command: command, prompt: prompt)
        return try await MainActor.run {
            var failure: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&failure)
            if let failure {
                let code = failure[NSAppleScript.errorNumber] as? Int ?? 1
                let message = (failure[NSAppleScript.errorMessage] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIExecutionError(
                    exitCode: Int32(clamping: code),
                    message: isUserCancellation(code: code, message: message)
                        ? cancelled
                        : (message.isEmpty ? failed : message))
            }
            return output?.stringValue ?? ""
        }
    }

    /*
     The AppleScript that raises the prompt.

     THREE strings meet in one literal: the CLI path (already shell-quoted), the command, and the
     prompt text. Every one of them goes through appleScriptQuoted, because a stray quote in any of
     them ends the literal early and changes what runs as root. The prompt is the one most likely to
     be reworded later by somebody not thinking about escaping.
    */
    static func privilegedScript(command: String, prompt: String) -> String {
        "do shell script \"\(appleScriptQuoted(command))\""
            + " with prompt \"\(appleScriptQuoted(prompt))\""
            + " with administrator privileges"
    }

    /// What the dialog says it wants, above the password field. One sentence per action: the dialog
    /// is the only place a person is told which of them they are approving.
    static let installPrompt = "RunOS Desktop needs to install the RunOS VPN service."
    static let restartPrompt = "RunOS Desktop needs to restart the RunOS VPN service so it runs the version you just installed."

    /*
     The restart prompt, with a sentence about what the restart does to the connection that is true
     of THIS machine right now.

     "Reconnects by itself" is only true when a tunnel is up and its session is still valid: the
     restarted service resumes the stored session. With no tunnel there is nothing to reconnect, and
     with a lapsed session the service comes back without a tunnel until the person signs in.
     Promising a reconnect in those states would be a claim the product does not keep.
    */
    static func restartPromptText(tunnelUp: Bool, sessionValid: Bool) -> String {
        guard tunnelUp else { return restartPrompt }
        if sessionValid {
            return restartPrompt + " The VPN disconnects for a few seconds, then reconnects by itself."
        }
        return restartPrompt + " Your VPN session has ended, so the VPN stays off until you sign in again."
    }

    /*
     Whether the person pressed Cancel, which is a refusal and not a fault.

     -128 is the code for it. The message is checked too, because the shell command's own failures
     come back with their exit code rather than -128, and a cancellation reported as an error banner
     would tell somebody something went wrong when they had simply said no.
    */
    static func isUserCancellation(code: Int, message: String) -> Bool {
        code == -128 || message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled")
    }

    /*
     The command run as root, and why it carries SUDO_USER.

     `runos vpn install` decides which group may open the control socket, so that the installing
     person reaches it WITHOUT sudo afterwards. It reads SUDO_USER to find who that person is.

     `with administrator privileges` is not sudo. It runs the command as root directly, so SUDO_USER
     is absent, and the CLI used to fall back to the effective user's primary group: root's, which
     is `wheel` on macOS. An ordinary account is in `staff` and `admin`, NOT `wheel`, so the daemon
     installed, started, and was then unreachable by the very person who installed it, with
     `vpn status` reporting "the RunOS VPN service is not running" while the process ran fine.
     Measured 2026-08-25, and reported again by two users on 2026-08-31, which is what finally
     traced it: the CLI no longer derives that group from root, and its daemon repairs a socket
     already in that state. Setting SUDO_USER here remains the right thing regardless, because it
     names the person whose CLI has to reach the socket.

     It is set INSIDE the command rather than passed as an env var, because AppleScript does not
     forward this process's environment.
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

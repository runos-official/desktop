import AppKit
import Combine
import Foundation

@MainActor
final class RefreshCoordinator: ObservableObject {
    let store: StateStore
    private let runner: CLIRunner?
    private var pollTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var actionRunning = false
    private var hasStarted = false
    private var storeObservation: AnyCancellable?

    init(store: StateStore, runner: CLIRunner?) {
        self.store = store
        self.runner = runner
        storeObservation = store.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        store.cliAvailable = runner != nil
    }

    /// The account the VPN switch was last attempted for, so it is tried once and not every poll.

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        schedulePoll()
        Task { await refresh() }
    }

    func setMenuOpen(_ isOpen: Bool) {
        menuIsOpen = isOpen
        schedulePoll()
        if isOpen {
            Task { await refresh() }
        }
    }

    func refresh() async {
        await refresh(allowDuringAction: false)
    }

    private func refresh(allowDuringAction: Bool) async {
        guard (allowDuringAction || !actionRunning), let runner else { return }
        do {
            let version = try await runner.run(["--version"])
            let currentVersion = String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let compatibility = VersionComparator.compatibility(currentVersion, minimum: minimumCLIVersion)
            update(\.cliVersion, to: currentVersion)
            update(\.cliDevelopment, to: compatibility == .development)
            update(\.cliOutdated, to: compatibility == .outdated)
            if compatibility == .outdated {
                update(\.errorMessage, to: "RunOS Desktop requires CLI \(minimumCLIVersion) or newer. Run 'runos update'.")
                return
            }
            if compatibility == .invalid {
                update(\.errorMessage, to: "RunOS Desktop cannot identify CLI version '\(currentVersion)'. Run 'runos update'.")
                return
            }
            let statusResult = try await runner.run(["status", "--json"])
            /*
             NOT `try?`. Discarding this error is what made a missing VPN service invisible: the
             status became nil, the menu rendered "disconnected", and the CLI's own sentence naming
             the daemon and its remedy was thrown away (reported 2026-08-25). The failure is now
             classified: a missing service is a state with a button, anything else is an error.
            */
            var vpnResult: CLIResult?
            do {
                vpnResult = try await runner.run(["vpn", "status", "--json"])
                update(\.vpnServiceMissing, to: false)
            } catch {
                let missing = VPNService.isMissing(error)
                update(\.vpnServiceMissing, to: missing)
                if !missing { update(\.errorMessage, to: error.localizedDescription) }
            }
            let status = try statusResult.decode(CLIStatus.self)
            let vpn = try? vpnResult?.decode(VPNStatus.self)
            update(\.cliStatus, to: status)
            update(\.vpnStatus, to: vpn)
            if let vpn, vpn.running {
                store.traffic.record(total: vpn.totalTrafficBytes)
            }
            /*
             Being signed out is a STATE, not an error, and it has a Sign In button. Promoting the
             CLI's sentence to the error banner put terminal wording in the menu explaining something
             the app already offers to fix.

             A REACHABILITY failure is neither (FCR160). `authErrorKind == "network"` means the token
             refresh could not COMPLETE, which says nothing about the sign-in; it used to arrive here
             as `authenticated: false` carrying a raw Go error with a request URL and an API key in
             it, and this line rendered that verbatim in the menu bar. It still shows, because a
             person whose menu has gone quiet should know the app cannot reach anything, but it shows
             as the one sentence the CLI now writes for it.
            */
            update(\.errorMessage, to: store.signInRequired ? nil : status.authError)
        } catch {
            update(\.errorMessage, to: error.localizedDescription)
        }
    }

    /*
     THE APP NO LONGER FOLLOWS AN ACCOUNT SWITCH BY ITSELF (FPL26 D3).

     It used to notice `vpnAccountMismatch` and run `vpn up --non-interactive` to move the tunnel
     onto the account the CLI had switched to. Two things were wrong with that. It could not work:
     the device key and the device id are both account-scoped, and the connect path reused the
     previous account's, so conductor answered 404 or the tunnel came up on a key it had never seen
     and routed nothing. And it should not: a tunnel appearing on a different account without being
     asked for is a surprise on the security-sensitive side.

     The rule now is that the tunnel never outlives the identity that opened it. `runos logout` and
     an account change both drop it, in the CLI, where the identity actually lives. This app simply
     reads the result, and the person clicks Connect when they want the new account connected.
    */

    func perform(
        _ arguments: [String],
        message: String,
        cancellable: Bool = false,
        cancelLabel: String = "Cancel Sign In",
        cancellingMessage: String = "Cancelling sign in…"
    ) {
        guard !actionRunning, let runner else { return }
        actionRunning = true
        store.operationMessage = message
        store.canCancelOperation = cancellable
        store.cancelOperationLabel = cancellable ? cancelLabel : nil
        store.cancellingOperationMessage = cancellable ? cancellingMessage : nil
        store.errorMessage = nil
        actionTask = Task {
            do {
                _ = try await runner.run(arguments)
            } catch is CancellationError {
            } catch {
                store.errorMessage = error.localizedDescription
            }
            let wasCancelled = Task.isCancelled
            store.canCancelOperation = false
            store.cancelOperationLabel = nil
            store.cancellingOperationMessage = nil
            if !wasCancelled {
                await refresh(allowDuringAction: true)
            }
            actionRunning = false
            store.operationMessage = nil
            actionTask = nil
        }
    }

    /*
     Open the device-code window and let it drive the CLI.

     Not `perform`: that captures output and shows a spinner, which is exactly what hid the device
     id and the URL. The window streams the command and shows both, then refreshes here when the CLI
     exits 0.

     The PURPOSE decides which command runs and what the window says. Signing in and confirming a
     sign-in are different things and this app no longer spells them the same way; see
     `SignInPurpose`.
    */
    func beginSignIn(purpose: SignInPurpose = .signIn) {
        guard !actionRunning else { return }
        SignInWindowController.shared.show(
            runner: runner,
            purpose: purpose,
            onFinished: { [weak self] in
                Task { await self?.refresh() }
            },
            onEnded: { [weak self] in
                self?.store.operationMessage = nil
            }
        )
    }

    /*
     End the identity. `runos logout` drops the tunnel with it (FPL26 D3), so this is one command.

     It used to be `vpn down`, which ended the VPN session and left the machine signed in, which is
     how one invocation of `runos status` came to report `"authenticated": false` beside
     `"vpnRunning": true`.
    */
    func signOut() {
        perform(DesktopCommands.signOut(), message: "Signing out…")
    }

    /*
     Install the VPN system service, the one thing `runos desktop install` cannot do for itself.

     The daemon runs as root, so this is the single point in the app that asks for an administrator
     password, and it asks through the OS rather than a box of its own (see VPNService.install).
     Refresh follows on success, so the menu goes straight from the offer to a usable VPN without
     the person doing anything else.
    */
    func installVPNService() {
        guard !actionRunning else { return }
        actionRunning = true
        store.operationMessage = "Installing the RunOS VPN service…"
        store.errorMessage = nil
        actionTask = Task {
            do {
                _ = try await VPNService.install(cliPath: CLIPathResolver.resolve().path)
                store.vpnServiceMissing = false
            } catch {
                store.errorMessage = error.localizedDescription
            }
            store.operationMessage = nil
            actionRunning = false
            await refresh(allowDuringAction: true)
        }
    }

    func cancelOperation() {
        guard actionRunning, store.canCancelOperation else { return }
        store.operationMessage = store.cancellingOperationMessage ?? "Cancelling…"
        store.canCancelOperation = false
        actionTask?.cancel()
    }

    /*
     The connect the app performs on its own at startup, when the person asked for it.

     Not cancellable, because there is nobody at the menu to cancel it, and it fails rather than
     opening a browser (see DesktopCommands.connectVPNAtStartup). A failure lands in the usual
     error line, which is right: they asked for a connection and did not get one, and the CLI's
     sentence says what is missing.
    */
    func connectVPNAtStartup() {
        perform(DesktopCommands.connectVPNAtStartup(), message: "Connecting VPN…")
    }

    /*
     Take the tunnel down. Bringing it UP goes through the device-code window instead
     (`beginSignIn(purpose: .confirm)`), because conductor can ask for a browser check first and a
     spinner cannot show a device code.
    */
    func disconnectVPN() {
        perform(DesktopCommands.setVPN(enabled: false), message: "Disconnecting VPN…")
    }

    func updateRunOS() {
        guard !actionRunning, let runner else { return }
        actionRunning = true
        store.operationMessage = "Updating RunOS…"
        store.errorMessage = nil
        Task {
            do {
                let result = try await runner.run(["update", "--json"])
                let update = try result.decode(UpdateResult.self)
                if update.desktop?.updated == true {
                    _ = try await runner.run(["desktop", "relaunch", "--wait-pid", String(ProcessInfo.processInfo.processIdentifier)])
                    NSApplication.shared.terminate(nil)
                    return
                }
            } catch {
                store.errorMessage = error.localizedDescription
            }
            await refresh(allowDuringAction: true)
            actionRunning = false
            store.operationMessage = nil
        }
    }

    private func schedulePoll() {
        pollTask?.cancel()
        let interval = menuIsOpen ? Duration.seconds(5) : Duration.seconds(30)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private var minimumCLIVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "RunOSMinimumCLIVersion") as? String ?? "1.15.0"
    }

    private func update<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<StateStore, Value>,
        to value: Value
    ) {
        guard store[keyPath: keyPath] != value else { return }
        store[keyPath: keyPath] = value
    }
}

enum CLIVersionCompatibility: Equatable {
    case supported
    case outdated
    case development
    case invalid
}

enum VersionComparator {
    static func compatibility(_ value: String, minimum: String) -> CLIVersionCompatibility {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "dev" || normalized.hasPrefix("dev-") {
            return .development
        }
        guard releaseComponents(normalized) != nil, releaseComponents(minimum) != nil else {
            return .invalid
        }
        return isOlder(normalized, than: minimum) ? .outdated : .supported
    }

    static func isOlder(_ value: String, than minimum: String) -> Bool {
        guard let lhs = releaseComponents(value), let rhs = releaseComponents(minimum) else {
            return false
        }
        for index in 0..<3 {
            let left = lhs.numbers[index]
            let right = rhs.numbers[index]
            if left != right { return left < right }
        }
        if lhs.prerelease == rhs.prerelease { return false }
        return lhs.prerelease != nil && rhs.prerelease == nil
    }

    private static func releaseComponents(_ value: String) -> (numbers: [Int], prerelease: String?)? {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("v") {
            normalized.removeFirst()
        }
        let versionParts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberParts = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numberParts.count == 3 else { return nil }
        let numbers = numberParts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        guard versionParts.count == 2 else { return (numbers, nil) }
        let prerelease = String(versionParts[1])
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !prerelease.isEmpty,
              prerelease.unicodeScalars.allSatisfy(allowed.contains),
              !prerelease.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else { return nil }
        return (numbers, prerelease)
    }
}

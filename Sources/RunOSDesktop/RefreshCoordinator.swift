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
    private var switchAttemptedForAccount: String?

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
            let vpnResult = try? await runner.run(["vpn", "status", "--json"])
            let status = try statusResult.decode(CLIStatus.self)
            let vpn = try? vpnResult?.decode(VPNStatus.self)
            update(\.cliStatus, to: status)
            update(\.vpnStatus, to: vpn)
            if let vpn, vpn.running {
                store.traffic.record(total: vpn.totalTrafficBytes)
            }
            update(\.errorMessage, to: status.authError)
            await followCLIAccount(status, vpn: vpn)
        } catch {
            update(\.errorMessage, to: error.localizedDescription)
        }
    }

    /*
     Keep the VPN on the account the person is signed in to, without telling them about it.

     The app used to report "the CLI is on abcde, the VPN is on fghij" and offer a button. That
     asks a person to reconcile two account states they never knew existed, to fix something the
     app can fix itself; which is exactly what it now does. `vpn up --non-interactive` is silent
     when the sign-in is recent enough, and after an account switch it usually is.

     ONLY WHILE THE TUNNEL IS UP, and once per account rather than once per poll: a person whose sign-in has genuinely expired would
     otherwise have this run against Conductor every few seconds for as long as the menu is open.
     A failure is not an error banner either. It means one thing a person can act on, so it sets
     the sign-in prompt and nothing else.
    */
    private func followCLIAccount(_ status: CLIStatus, vpn: VPNStatus?) async {
        // Only ever while the tunnel is ALREADY up. `vpn up` signs in AND connects, so following
        // the account on a stopped VPN turned it on for someone who never asked. Connecting is
        // their decision (the Connect button, or the startup preference), never a side effect of
        // the app tidying its own state. A VPN that is down is also showing nobody anything wrong.
        guard vpn?.running == true else {
            switchAttemptedForAccount = nil
            update(\.vpnSignInRequired, to: false)
            return
        }
        guard status.vpnAccountMismatch == true, let account = status.accountId else {
            switchAttemptedForAccount = nil
            update(\.vpnSignInRequired, to: false)
            return
        }
        guard switchAttemptedForAccount != account, let runner else { return }
        switchAttemptedForAccount = account
        do {
            _ = try await runner.run(DesktopCommands.connectVPNAtStartup())
            update(\.vpnSignInRequired, to: false)
        } catch {
            update(\.vpnSignInRequired, to: true)
        }
    }

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
     Open the sign-in window and let it drive the CLI.

     Not `perform`: that captures output and shows a spinner, which is exactly what hid the device
     id and the URL. The window streams the same command and shows both, then refreshes here when
     the CLI exits 0.
    */
    func beginSignIn() {
        guard !actionRunning else { return }
        SignInWindowController.shared.show(runner: runner) { [weak self] in
            Task { await self?.refresh() }
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

    func setVPN(enabled: Bool) {
        perform(
            DesktopCommands.setVPN(enabled: enabled),
            message: enabled ? "Connecting VPN…" : "Signing out…",
            cancellable: enabled,
            cancelLabel: "Cancel Connection",
            cancellingMessage: "Cancelling connection…"
        )
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

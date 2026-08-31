import AppKit
import Combine
import Foundation

@MainActor
final class RefreshCoordinator: ObservableObject {
    let store: StateStore
    /*
     A VAR, because a CLI can be installed while this app is running.

     It used to be a `let` resolved once at launch. First launch with no CLI showed "RunOS Desktop
     cannot find the RunOS CLI. Install or update the CLI, then run 'runos desktop install'.", the
     person followed that instruction, and NOTHING changed: `refresh` returns immediately while this
     is nil, so the message was never re-evaluated and the whole menu stayed inert until the app was
     quit and reopened. The app told somebody to do a thing and then ignored them doing it.
    */
    private var runner: CLIRunner?
    private var pollTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?

    /*
     The sign-in state the previous refresh saw, so a sign-in COMPLETING can be told from simply
     being signed in. nil means nothing has been read yet.

     See AutoConnect.shouldConnect for why this has to be a transition: "signed in with the tunnel
     down" is also true one second after somebody clicks Disconnect.
    */
    private var wasSignedIn: Bool?

    /*
     When the update check may run again. See `checkForUpdatesIfDue` for why it is not on the poll.

     A DEADLINE rather than a "last ran", because a failed check must come back sooner than a
     successful one. Recording the attempt up front meant one unreachable minute silenced the check
     for six hours.
    */
    private var nextUpdateCheck: Date?

    /// The CLI build the previous refresh saw. A change means somebody updated outside this app,
    /// which is the one event that makes the cached update answer wrong immediately.
    private var lastSeenCLIVersion: String?
    /*
     Which refresh is current, so a slow one cannot write its result over a newer one.

     Nothing serialises `refresh`: the guard covers a running ACTION, not another refresh, and
     `CLIRunner` is an actor that SUSPENDS at its continuation, so concurrent runs interleave rather
     than queue. Two are reachable together whenever the menu is opened while a poll is in flight,
     and the poll keeps firing every 30 seconds throughout a sign-in that is waiting on a person.

     The older refresh finishes second and publishes a status read before the newer one, so the menu
     lands on stale facts: signed out after a sign-in completed, or a tunnel drawn as up after it
     went down.
    */
    private var refreshGeneration = 0
    private var menuIsOpen = false
    private var actionRunning = false
    private var hasStarted = false
    private var storeObservation: AnyCancellable?

    /// The auto-connect preference, injected so a test can hand in its own UserDefaults rather than
    /// reading the developer's real one.
    private let autoConnect: StartupConnectController

    init(store: StateStore, runner: CLIRunner?, autoConnect: StartupConnectController = StartupConnectController()) {
        self.store = store
        self.runner = runner
        self.autoConnect = autoConnect
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

    /// Re-resolves the CLI path, for the case where it was missing at launch and has since been
    /// installed. Silent on failure: the message from launch is still the right one.
    private func adoptNewlyInstalledCLI() {
        guard let found = try? CLIRunner(executableURL: CLIPathResolver.resolve()) else { return }
        runner = found
        update(\.cliAvailable, to: true)
        update(\.errorMessage, to: nil)
    }

    private func refresh(allowDuringAction: Bool) async {
        guard allowDuringAction || !actionRunning else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        // Look again before giving up: the poll then picks up a CLI installed since launch on its
        // own, within one cycle, and clears the message that asked for it.
        if runner == nil { adoptNewlyInstalledCLI() }
        guard let runner else { return }
        do {
            let version = try await runner.run(["--version"])
            let currentVersion = String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let compatibility = VersionComparator.compatibility(currentVersion, minimum: minimumCLIVersion)
            /*
             A CLI THAT CHANGED UNDER US INVALIDATES THE UPDATE ANSWER, at once.

             Reported 2026-08-31: the operator ran `runos update` in a terminal, and the menu went
             on offering an update that no longer existed, because this check only runs every six
             hours. Their word for the whole sequence was "VERY janky".

             The version is already read on every refresh for the compatibility floor, so noticing
             it changed costs nothing. This is the one event that makes the cached answer wrong
             immediately rather than eventually.
            */
            if let seen = lastSeenCLIVersion, seen != currentVersion {
                nextUpdateCheck = nil
            }
            lastSeenCLIVersion = currentVersion
            update(\.cliVersion, to: currentVersion)
            update(\.cliDevelopment, to: compatibility == .development)
            update(\.cliOutdated, to: compatibility == .outdated)
            /*
             A CLI THIS APP CANNOT WORK WITH STILL LEAVES UPDATE CLICKABLE.

             Both of these returned before `checkForUpdatesIfDue` ever ran, so `updateVerdictKnown`
             stayed nil, which `updateActionEnabled` reads as "nothing asked yet" and renders
             disabled. The machine with the outdated CLI was therefore the one machine where the
             control that fixes it could not be pressed, and the only route left was the terminal
             command the menu item exists to save somebody from.

             `false` is the honest value: we asked nothing and learned nothing, which is not
             evidence that no update exists. The three-state verdict was introduced for exactly
             this, and these two paths were missed.
            */
            if compatibility == .outdated {
                update(\.updateVerdictKnown, to: false)
                update(\.errorMessage, to: "RunOS Desktop requires CLI \(minimumCLIVersion) or newer. Run 'runos update'.")
                return
            }
            if compatibility == .invalid {
                update(\.updateVerdictKnown, to: false)
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
            /*
             HELD, NOT ASSIGNED. A refresh writes `errorMessage` exactly ONCE, at the end.

             This used to assign here and be overwritten twenty-one lines below by the unconditional
             `authError` line, in the same synchronous pass, so SwiftUI never rendered it: a VPN
             daemon that refused to answer produced an ordinary submenu offering Connect and no word
             anywhere about the refusal. Anything that wants to report a failure from inside a
             refresh puts it in this variable.
            */
            var refreshFailure: String?
            var vpnResult: CLIResult?
            do {
                vpnResult = try await runner.run(["vpn", "status", "--json"])
                update(\.vpnServiceMissing, to: false)
            } catch {
                let missing = VPNService.isMissing(error)
                update(\.vpnServiceMissing, to: missing)
                if !missing { refreshFailure = error.localizedDescription }
            }
            let status = try statusResult.decode(CLIStatus.self)
            let vpn = try? vpnResult?.decode(VPNStatus.self)
            // A newer refresh started while this one was waiting on the CLI, so this answer is
            // already out of date. Publishing it would put the older facts on screen.
            guard generation == refreshGeneration else { return }
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
            update(\.errorMessage, to: refreshFailure ?? (store.signInRequired ? nil : status.authError))
            autoConnectIfASignInJustCompleted()
            await checkForUpdatesIfDue()
        } catch is CancellationError {
            /*
             A CANCELLATION IS THE APP TIDYING UP, NOT SOMETHING TO REPORT.

             The poll task is cancelled on every teardown and on every reschedule. Swift's own
             CancellationError has no message written for a person: its localizedDescription is
             "The operation couldn't be completed. (Swift.CancellationError error 1.)", which this
             put straight into the menu and, because `menuBarState` reads any errorMessage as
             trouble, turned the menu bar icon to the attention state for a routine reschedule.

             Nothing is lost by staying quiet. The next refresh reports whatever is really wrong.
            */
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

    /*
     Bring the VPN up when a sign-in has just made it possible, and the person asked for that.

     Reported: "i have connect vpn at startup selected, but after logging in, it doesn't auto
     connect." The startup connect ran once in the app's init, while the person was still signed out,
     and nothing retried. This is the retry, and it happens at the only moment worth retrying at.

     `--non-interactive`, so it can never open a browser on its own: a browser window appearing
     unasked is worse than staying disconnected. A refusal is left to the ordinary status paths
     rather than shouted about, because the person did not press anything.
    */
    /// The moment the deadline policy is measured against. A var so a test can move time rather
    /// than wait six hours for the interval this exists to enforce.
    var now: () -> Date = Date.init

    private func autoConnectIfASignInJustCompleted() {
        /*
         A CHECK THAT COULD NOT COMPLETE IS NOT AN OBSERVATION.

         `signedIn` is a bare `authenticated == true`, and the CLI reports `authenticated: false`
         with `authErrorKind: "network"` for a token refresh that could not REACH anything, not only
         for one that was refused (FCR160). It refreshes on every `runos status`, so any poll taken
         offline produces that payload.

         Recording it as "was signed out" manufactured a sign-in transition on the way back:
         somebody clicks Disconnect and walks into a lift, one poll reports the network kind, the
         next poll reports the sign-in that never went anywhere, and auto-connect reads that as a
         fresh sign-in and reopens the tunnel they deliberately closed.

         Leaving the memory alone is right: nothing was learned, so nothing changed.
        */
        guard store.cliStatus?.authErrorKind != "network" else { return }
        let signedIn = store.signedIn
        defer { wasSignedIn = signedIn }
        guard AutoConnect.shouldConnect(
            enabled: autoConnect.isEnabled,
            wasSignedIn: wasSignedIn,
            isSignedIn: signedIn,
            tunnelRunning: store.vpnStatus?.running == true
        ) else { return }
        connectVPNAtStartup()
    }

    /*
     Ask whether an update is waiting, RARELY.

     Not on the ordinary poll. That runs every five seconds with the menu open, and this check
     reaches conductor and GitHub; asking a release feed twelve times a minute to answer a question
     whose answer changes a few times a month would be rude to both. Once on the first refresh, then
     every six hours, which is well inside the time anyone would notice a new release.

     A failure is silent and leaves the previous answer standing. Not knowing whether an update
     exists is not worth an error banner, and it must never disable the VPN controls.
    */
    private func checkForUpdatesIfDue() async {
        let now = self.now()
        guard let runner else { return }
        if let next = nextUpdateCheck, now < next { return }
        guard let result = try? await runner.run(["update", "--check", "--json"]),
              let check = try? result.decode(UpdateCheck.self) else {
            /*
             ASKED, AND GOT NOTHING USABLE. That is a verdict-less answer, not a state of having
             never asked, and the difference decides whether Update RunOS is clickable.

             Leaving it unset would keep the item DISABLED for as long as the check kept failing, so
             a machine that could not reach the release feed would have no way to update at all.
            */
            update(\.updateVerdictKnown, to: false)
            // RETRY SOON, not in six hours. The interval exists to be polite about a question whose
            // answer changes a few times a month, not to punish a machine for one bad minute. A
            // network blip on the morning this shipped would otherwise have left the app with no
            // verdict until the evening.
            nextUpdateCheck = now.addingTimeInterval(updateRetryInterval)
            return
        }
        update(\.updateAvailable, to: check.anyAvailable)
        update(\.updateVerdictKnown, to: check.verdictKnown)
        nextUpdateCheck = now.addingTimeInterval(updateCheckInterval)
    }

    /// Six hours. A release lands a few times a month, so anything shorter is noise on somebody
    /// else's servers.
    private let updateCheckInterval: TimeInterval = 6 * 60 * 60

    /// After a check that could not run. Long enough not to hammer a service that is down, short
    /// enough that a passing blip does not cost the rest of the day.
    private let updateRetryInterval: TimeInterval = 5 * 60

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
            /*
             HELD UNTIL AFTER THE REFRESH. Assigning `store.errorMessage` here and then refreshing
             lost the sentence: the refresh ends by writing `errorMessage` itself, so the failure
             was nil again before the menu ever drew. `store.errorMessage` is the menu's only
             failure surface, so a failed Disconnect, Sign Out or cluster toggle read as a dead
             click: the tunnel stayed up and the app said nothing.
            */
            var failure: String?
            do {
                _ = try await runner.run(arguments)
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            let wasCancelled = Task.isCancelled
            store.canCancelOperation = false
            store.cancelOperationLabel = nil
            store.cancellingOperationMessage = nil
            if !wasCancelled {
                await refresh(allowDuringAction: true)
            }
            if let failure { store.errorMessage = failure }
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
        /*
         CLAIMED, so the guard above is worth something.

         It was never assigned on this path, so the guard never fired: the Sign In button stays
         enabled for the whole login (a `.signIn` sets no operationMessage, so `isBusy` is false),
         and the panel is non-modal so the menu bar stays clickable. The CLI runs with --no-browser,
         so nothing opens by itself and somebody who reads the click as dead clicks again, starting
         a second `runos login` beside the first. It also let a Disconnect or a Sign Out start in
         the middle of a sign-in.
        */
        actionRunning = true
        /*
         A CONFIRMATION USUALLY OPENS NO WINDOW, so the menu has to say something instead.

         Without this a Connect that needs no confirmation is completely silent: the menu closes,
         nothing changes for a second or two, and the click reads as dead. The message is cleared on
         `onEnded`, which fires however the run finishes, window or no window.
        */
        if !purpose.presentsWindowImmediately {
            store.operationMessage = purpose.busyMessage
        }
        SignInWindowController.shared.show(
            runner: runner,
            purpose: purpose,
            onFinished: { [weak self] in
                Task { await self?.refresh() }
            },
            /*
             A run that never opened a window still has to report. `.confirm` defers its window
             until a device code arrives, and `runos vpn up` can fail before there is one, which
             used to leave "Connecting VPN…" appearing and vanishing with nothing said anywhere.
            */
            onEnded: { [weak self] failure in
                guard let self else { return }
                self.actionRunning = false
                self.store.operationMessage = nil
                if let failure { self.store.errorMessage = failure }
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
            // Held until after the refresh, which writes `errorMessage` itself. See `perform`.
            var failure: String?
            do {
                _ = try await VPNService.install(cliPath: CLIPathResolver.resolve().path)
                store.vpnServiceMissing = false
            } catch {
                failure = error.localizedDescription
            }
            store.operationMessage = nil
            actionRunning = false
            await refresh(allowDuringAction: true)
            if let failure { store.errorMessage = failure }
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
        // Whatever the answer was, it is stale the moment this runs.
        nextUpdateCheck = nil
        actionRunning = true
        store.operationMessage = "Updating RunOS…"
        store.isUpdating = true
        store.errorMessage = nil
        Task {
            // Held until after the refresh, which writes `errorMessage` itself. See `perform`.
            var failure: String?
            do {
                let result = try await runner.run(["update", "--json"])
                let update = try result.decode(UpdateResult.self)
                if update.desktop?.updated == true {
                    _ = try await runner.run(["desktop", "relaunch", "--wait-pid", String(ProcessInfo.processInfo.processIdentifier)])
                    NSApplication.shared.terminate(nil)
                    return
                }
            } catch {
                failure = error.localizedDescription
            }
            await refresh(allowDuringAction: true)
            if let failure { store.errorMessage = failure }
            actionRunning = false
            store.isUpdating = false
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

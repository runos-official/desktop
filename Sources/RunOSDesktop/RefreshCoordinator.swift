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
        guard !actionRunning, let runner else { return }
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
            let accountsResult = try await runner.run(["account", "list", "--json"])
            let vpnResult = try? await runner.run(["vpn", "status", "--json"])
            let status = try statusResult.decode(CLIStatus.self)
            let accounts = try accountsResult.decode(AccountListResult.self)
            let vpn = try? vpnResult?.decode(VPNStatus.self)
            update(\.cliStatus, to: status)
            update(\.accounts, to: accounts.accounts)
            update(\.vpnStatus, to: vpn)
            update(\.errorMessage, to: status.authError)
        } catch {
            update(\.errorMessage, to: error.localizedDescription)
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
            actionRunning = false
            store.operationMessage = nil
            store.canCancelOperation = false
            store.cancelOperationLabel = nil
            store.cancellingOperationMessage = nil
            actionTask = nil
            if !wasCancelled {
                await refresh()
            }
        }
    }

    func cancelOperation() {
        guard actionRunning, store.canCancelOperation else { return }
        store.operationMessage = store.cancellingOperationMessage ?? "Cancelling…"
        store.canCancelOperation = false
        actionTask?.cancel()
    }

    func setVPN(enabled: Bool) {
        perform(
            DesktopCommands.setVPN(enabled: enabled),
            message: enabled ? "Connecting VPN…" : "Disconnecting VPN…",
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
            actionRunning = false
            store.operationMessage = nil
            await refresh()
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

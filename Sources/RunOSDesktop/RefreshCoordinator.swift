import AppKit
import Foundation

@MainActor
final class RefreshCoordinator: ObservableObject {
    let store: StateStore
    private let runner: CLIRunner?
    private var pollTask: Task<Void, Never>?
    private var menuIsOpen = false
    private var actionRunning = false

    init(store: StateStore, runner: CLIRunner?) {
        self.store = store
        self.runner = runner
        store.cliAvailable = runner != nil
    }

    func start() {
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
            store.cliOutdated = VersionComparator.isOlder(currentVersion, than: minimumCLIVersion)
            guard !store.cliOutdated else {
                store.errorMessage = "RunOS Desktop requires CLI \(minimumCLIVersion) or newer. Run 'runos update'."
                return
            }
            async let statusResult = runner.run(["status", "--json"])
            async let accountsResult = runner.run(["account", "list", "--json"])
            async let vpnResult = runner.run(["vpn", "status", "--json"])
            let status = try await statusResult.decode(CLIStatus.self)
            let accounts = try await accountsResult.decode(AccountListResult.self)
            let vpn = try? await vpnResult.decode(VPNStatus.self)
            store.cliStatus = status
            store.accounts = accounts.accounts
            store.vpnStatus = vpn
            store.errorMessage = status.authError
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    func perform(_ arguments: [String], message: String) {
        guard !actionRunning, let runner else { return }
        actionRunning = true
        store.operationMessage = message
        store.errorMessage = nil
        Task {
            do {
                _ = try await runner.run(arguments)
            } catch {
                store.errorMessage = error.localizedDescription
            }
            actionRunning = false
            store.operationMessage = nil
            await refresh()
        }
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
}

enum VersionComparator {
    static func isOlder(_ value: String, than minimum: String) -> Bool {
        let lhs = components(value)
        let rhs = components(minimum)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func components(_ value: String) -> [Int] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            .split(separator: "-").first?
            .split(separator: ".").map { Int($0) ?? 0 } ?? []
    }
}

import XCTest
@testable import RunOSDesktop

/*
 Switching account from the menu bar.

 Account sharing lets one login belong to several accounts, and the CLI switches between them
 without a browser. The menu lists them from `runos user accounts --json` and switches with
 `runos account switch <aid> --json`. The list is read on every refresh while signed in, and a CLI
 too old to have the command leaves the list empty rather than failing the refresh.
*/
final class AccountSwitchTests: XCTestCase {
    private let accounts = #"{"accounts":[{"aid":"acct1","name":"","companyName":"Example Company","accountRole":"admin","isDefault":true},{"aid":"acct2","name":"Lab","companyName":null,"accountRole":"limited","isDefault":false},{"aid":"acct3","name":"","companyName":null,"accountRole":"admin","isDefault":false}]}"#

    func testUserAccountsDecodeAndLabelLikeTheConsole() throws {
        let result = try JSONDecoder.runOS.decode(UserAccountsResult.self, from: Data(accounts.utf8))

        XCTAssertEqual(result.accounts.map(\.aid), ["acct1", "acct2", "acct3"])
        // Company name, then account name, then the bare id: the same rule the console uses.
        XCTAssertEqual(result.accounts.map(\.label), ["Example Company", "Lab", "acct3"])
        XCTAssertEqual(result.accounts.first?.isDefault, true)
    }

    func testTheSwitchCommandNamesTheAccountAndAsksForJSON() {
        XCTAssertEqual(DesktopCommands.listAccounts(), ["user", "accounts", "--json"])
        XCTAssertEqual(DesktopCommands.switchAccount("acct2"), ["account", "switch", "acct2", "--json"])
    }

    @MainActor
    func testARefreshListsTheAccountsWhileSignedIn() async throws {
        let executable = try makeFakeCLI(accounts: accounts)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertTrue(store.signedIn)
        XCTAssertEqual(store.accounts.map(\.aid), ["acct1", "acct2", "acct3"])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testACLIWithoutTheCommandLeavesTheListEmptyAndTheRefreshWhole() async throws {
        // An older CLI answers "unexpected command" and exits 7. That must not become the error
        // banner: the rest of the menu is unaffected.
        let executable = try makeFakeCLI(accounts: nil)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertTrue(store.signedIn)
        XCTAssertEqual(store.accounts, [])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testSigningOutClearsTheList() async throws {
        let executable = try makeFakeCLI(accounts: accounts, authenticated: false)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let store = StateStore()
        store.accounts = try JSONDecoder.runOS.decode(UserAccountsResult.self, from: Data(accounts.utf8)).accounts
        let coordinator = RefreshCoordinator(store: store, runner: try CLIRunner(executableURL: executable))

        await coordinator.refresh()

        XCTAssertFalse(store.signedIn)
        XCTAssertEqual(store.accounts, [])
    }

    @MainActor
    func testOnlyAnotherAccountIsOfferedAsASwitch() throws {
        let store = StateStore()
        store.cliStatus = try JSONDecoder.runOS.decode(
            CLIStatus.self,
            from: Data(#"{"schemaVersion":1,"authenticated":true,"accountId":"acct2","companyName":"Lab"}"#.utf8)
        )
        store.accounts = try JSONDecoder.runOS.decode(UserAccountsResult.self, from: Data(accounts.utf8)).accounts

        XCTAssertTrue(store.canSwitchAccount)
        XCTAssertEqual(store.accounts.filter { store.isActiveAccount($0) }.map(\.aid), ["acct2"])

        // One account is nothing to switch between, so the submenu stays away.
        store.accounts = Array(store.accounts.prefix(1))
        XCTAssertFalse(store.canSwitchAccount)
    }

    /// A fake CLI that is signed in (or not) and answers the account list, or knows no such command.
    private func makeFakeCLI(accounts: String?, authenticated: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "fake-runos")
        let status = #"{"schemaVersion":1,"authenticated":\#(authenticated),"accountId":"acct1","companyName":"Example Company"}"#
        let vpn = #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        let accountsCase = accounts.map { "  'user accounts --json') printf '%s\\n' '\($0)' ;;\n" } ?? ""
        let script = """
        #!/bin/sh
        case "$*" in
          '--version') printf 'dev-2026-08-17T11:42:49Z\\n' ;;
          'status --json') printf '%s\\n' '\(status)' ;;
          'vpn status --json') printf '%s\\n' '\(vpn)' ;;
        \(accountsCase)  *) printf 'unexpected command\\n' >&2; exit 7 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

import XCTest
@testable import RunOSDesktop

/*
 Between the sign-in window closing and the VPN being usable, the menu used to say nothing: Sign In
 stayed clickable while the app re-read its state, then everything greyed out for the automatic
 connect. The person had no way to know it was working, and clicked again. These tests pin the
 bridge: from the moment the window closes, the menu says what is happening, without a gap.
*/
final class SignInFinishingTests: XCTestCase {

    func testEveryPurposeSaysWhatItIsFinishing() {
        XCTAssertEqual(SignInPurpose.signIn.finishingMessage, "Finishing sign in…")
        XCTAssertEqual(SignInPurpose.confirm.finishingMessage, "Connecting VPN…")
        XCTAssertEqual(SignInPurpose.renew.finishingMessage, "Renewing VPN session…")
    }

    /// A fake CLI whose sign-in state is a file, so a test can sign the person in between refreshes.
    private func makeFakeCLI(connectSeconds: Int) throws -> (executable: URL, signedInFlag: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appending(path: "fake-runos")
        let flag = directory.appending(path: "signed-in")
        let vpn = #"{"schemaVersion":1,"running":false,"session":{"present":false,"loginRequired":false},"clusters":[]}"#
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(24 * 3600))
        let vpnUp = #"{"schemaVersion":1,"running":true,"session":{"present":true,"loginRequired":false,"expiresAt":""# + expires + #""},"clusters":[]}"#
        let script = """
        #!/bin/sh
        FLAG='\(flag.path)'
        case "$*" in
          '--version') printf 'dev-2026-08-17T11:42:49Z\\n' ;;
          'status --json')
            if [ -f "$FLAG" ]; then printf '%s\\n' '{"schemaVersion":1,"authenticated":true,"accountId":"acct1"}'
            else printf '%s\\n' '{"schemaVersion":1,"authenticated":false,"accountId":"acct1"}'; fi ;;
          'vpn status --json')
            if [ -f "$FLAG" ] && [ -f "$FLAG.up" ]; then printf '%s\\n' '\(vpnUp)'; else printf '%s\\n' '\(vpn)'; fi ;;
          'vpn up --non-interactive --json') sleep \(connectSeconds); printf '%s\\n' '\(vpn)' ;;
          *) printf 'unexpected command\\n' >&2; exit 7 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, flag)
    }

    @MainActor
    private func isolatedAutoConnect(enabled: Bool) -> StartupConnectController {
        let defaults = UserDefaults(suiteName: "runos-desktop-test-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: "connectVPNAtStartup")
        return StartupConnectController(defaults: defaults)
    }

    @MainActor
    func testTheMenuSaysFinishingFromTheMomentTheWindowClosesUntilTheStateIsRead() async throws {
        let cli = try makeFakeCLI(connectSeconds: 0)
        defer { try? FileManager.default.removeItem(at: cli.executable.deletingLastPathComponent()) }
        try Data().write(to: cli.signedInFlag)
        let store = StateStore()
        let coordinator = RefreshCoordinator(
            store: store, runner: try CLIRunner(executableURL: cli.executable),
            autoConnect: isolatedAutoConnect(enabled: false))

        let finishing = coordinator.signInFinished(purpose: .signIn)

        // Synchronously: nothing has been awaited, so no menu draw can fall between the window
        // closing and this message.
        XCTAssertEqual(store.operationMessage, "Finishing sign in…")
        XCTAssertTrue(store.isBusy)
        await finishing.value
        XCTAssertNil(store.operationMessage)
        XCTAssertTrue(store.signedIn)
    }

    @MainActor
    func testTheFinishingMessageHandsOverToTheAutomaticConnectWithoutAGap() async throws {
        let cli = try makeFakeCLI(connectSeconds: 2)
        defer { try? FileManager.default.removeItem(at: cli.executable.deletingLastPathComponent()) }
        let store = StateStore()
        let coordinator = RefreshCoordinator(
            store: store, runner: try CLIRunner(executableURL: cli.executable),
            autoConnect: isolatedAutoConnect(enabled: true))
        // The person starts signed out, so the next signed-in reading is a sign-in just completed.
        await coordinator.refresh()
        XCTAssertFalse(store.signedIn)
        try Data().write(to: cli.signedInFlag)

        await coordinator.signInFinished(purpose: .signIn).value

        // The refresh saw the sign-in and started the connect, which owns the message now. It must
        // not have been cleared in between, or Sign In and Connect would be clickable for a moment.
        XCTAssertEqual(store.operationMessage, "Connecting VPN…")
        let deadline = Date().addingTimeInterval(10)
        while store.operationMessage != nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(store.operationMessage)
    }

    // Renewing can finish with no window at all: a sign-in from the last five minutes needs no
    // browser check. Then nothing on screen says it happened, so the menu says it.
    @MainActor
    func testARenewThatFinishedSaysWhenTheNewSessionEnds() async throws {
        let cli = try makeFakeCLI(connectSeconds: 0)
        defer { try? FileManager.default.removeItem(at: cli.executable.deletingLastPathComponent()) }
        try Data().write(to: cli.signedInFlag)
        try Data().write(to: URL(fileURLWithPath: cli.signedInFlag.path + ".up"))
        let store = StateStore()
        let coordinator = RefreshCoordinator(
            store: store, runner: try CLIRunner(executableURL: cli.executable),
            autoConnect: isolatedAutoConnect(enabled: false))

        await coordinator.signInFinished(purpose: .renew).value

        let notice = try XCTUnwrap(store.noticeMessage)
        XCTAssertTrue(notice.hasPrefix("VPN session renewed."), notice)
        XCTAssertNil(store.operationMessage)
    }

    @MainActor
    func testASignInDoesNotClaimARenewal() async throws {
        let cli = try makeFakeCLI(connectSeconds: 0)
        defer { try? FileManager.default.removeItem(at: cli.executable.deletingLastPathComponent()) }
        try Data().write(to: cli.signedInFlag)
        let store = StateStore()
        let coordinator = RefreshCoordinator(
            store: store, runner: try CLIRunner(executableURL: cli.executable),
            autoConnect: isolatedAutoConnect(enabled: false))

        await coordinator.signInFinished(purpose: .signIn).value

        XCTAssertNil(store.noticeMessage)
    }

    func testTheRenewedNoticeNamesTheEndOfTheNewSession() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let session = VPNSession(present: true, expiresAt: now.addingTimeInterval(24 * 3600), loginRequired: false)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let notice = MenuPresentation.sessionRenewedNotice(session, now: now, timeZone: utc)
        XCTAssertEqual(notice, "VPN session renewed. It ends in 24h (\(clock(now.addingTimeInterval(24 * 3600), utc))).")
    }

    func testNoNoticeWhenThereIsNoValidSessionToNameTheEndOf() {
        let now = Date()
        XCTAssertNil(MenuPresentation.sessionRenewedNotice(nil, now: now))
        XCTAssertNil(MenuPresentation.sessionRenewedNotice(
            VPNSession(present: false, expiresAt: nil, loginRequired: false), now: now))
    }

    private func clock(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

import XCTest
@testable import RunOSDesktop

/*
 How a long CLI sentence reaches a person (FCR 1730, item 4).

 The sign-in window showed "Error: private DNS zone ... usually timing rather than a broken
 cluster. R…" and stopped, so the part that said what to do was never readable. The contract says a
 CLI error is not rewritten; it does not say it must fit on one line. A MENU LINE is a short,
 honest summary with Show Details beside it, and a WINDOW shows the whole text.
*/
final class ErrorPresentationTests: XCTestCase {

    private let limit = ErrorPresentation.menuLineLimit

    /// The sentence that was cut off in the sign-in window, anonymised.
    private let incidentSentence = "Error: private DNS zone example.test could not be applied. This is usually timing rather than a broken cluster. Run `runos vpn connect c-example1` again in a few seconds."

    // MARK: menu line

    func testAShortSentenceIsNotTouched() {
        let line = ErrorPresentation.menuLine("the VPN daemon is not answering")
        XCTAssertEqual(line, ErrorPresentation.Line(text: "the VPN daemon is not answering", isSummary: false))
    }

    func testASentenceOfExactlyTheLimitIsNotShortened() {
        let text = String(repeating: "a", count: limit)
        XCTAssertEqual(ErrorPresentation.menuLine(text), ErrorPresentation.Line(text: text, isSummary: false))
    }

    func testOneCharacterOverTheLimitIsShortenedAndSaysSo() {
        let line = ErrorPresentation.menuLine(String(repeating: "a", count: limit + 1))
        XCTAssertTrue(line.isSummary)
        XCTAssertLessThanOrEqual(line.text.count, limit)
        XCTAssertTrue(line.text.hasSuffix("\u{2026}"))
    }

    func testTheIncidentSentenceIsASummaryAndTheWholeIsStillAvailable() {
        let line = ErrorPresentation.menuLine(incidentSentence)
        XCTAssertTrue(line.isSummary)
        XCTAssertLessThanOrEqual(line.text.count, limit)
        // Nothing is lost: the window gets the text whole, remedy included.
        XCTAssertEqual(ErrorPresentation.fullText(incidentSentence), incidentSentence)
        XCTAssertTrue(ErrorPresentation.fullText(incidentSentence).hasSuffix("again in a few seconds."))
    }

    // Table of awkward inputs, each held to the same rules.
    private struct Case { let name: String; let input: String; let expectSummary: Bool }
    private var cases: [Case] {
        let longWord = String(repeating: "x", count: 400)
        return [
            Case(name: "plain long", input: String(repeating: "word ", count: 60), expectSummary: true),
            Case(name: "very long single word", input: longWord, expectSummary: true),
            Case(name: "long url", input: "see https://console.example.test/" + longWord, expectSummary: true),
            Case(name: "newlines", input: "first line\nsecond line\nthird", expectSummary: true),
            Case(name: "crlf", input: "first line\r\nsecond line", expectSummary: true),
            Case(name: "leading blank lines", input: "\n\n  \nreal line", expectSummary: false),
            Case(name: "backtick cut", input: String(repeating: "a", count: limit - 12) + " Run `runos vpn connect c-example1` now", expectSummary: true),
            Case(name: "many backticks", input: String(repeating: "`cmd` ", count: 40), expectSummary: true),
            Case(name: "only backticks", input: String(repeating: "`", count: 200), expectSummary: true),
            Case(name: "emoji", input: String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} ", count: 60), expectSummary: true),
            Case(name: "tabs and nul", input: "a\tb\u{0}c" + String(repeating: " d", count: 80), expectSummary: true),
            Case(name: "markdown", input: "**Error:** [link](https://example.test) " + String(repeating: "z", count: 120), expectSummary: true),
            Case(name: "unicode", input: String(repeating: "r\u{00E9}seau ", count: 40), expectSummary: true),
        ]
    }

    func testEveryAwkwardInputGivesOneShortLineWithNothingOpen() {
        for item in cases {
            let line = ErrorPresentation.menuLine(item.input)
            XCTAssertLessThanOrEqual(line.text.count, limit, item.name)
            XCTAssertFalse(line.text.contains("\n"), item.name)
            XCTAssertFalse(line.text.contains("\r"), item.name)
            XCTAssertFalse(line.text.unicodeScalars.contains { $0.properties.generalCategory == .control }, item.name)
            XCTAssertEqual(line.text.filter { $0 == "`" }.count % 2, 0, "\(item.name): a backtick is left open: \(line.text)")
            XCTAssertEqual(line.isSummary, item.expectSummary, item.name)
            XCTAssertFalse(line.text.isEmpty, item.name)
            // A shortened line is a prefix of the text with its whitespace collapsed, plus the ellipsis.
            if line.isSummary, line.text.hasSuffix("\u{2026}") {
                let collapsed = item.input.split(whereSeparator: { $0.isWhitespace || $0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control } }).joined(separator: " ")
                XCTAssertTrue(collapsed.hasPrefix(String(line.text.dropLast())), "\(item.name): the summary is not the start of the text")
            }
        }
    }

    func testAVeryLongWordIsCutAtTheLimitAndNotLeftAsALongLine() {
        let line = ErrorPresentation.menuLine(String(repeating: "x", count: 400))
        XCTAssertEqual(line.text.count, limit)
    }

    func testTheCutPrefersAWordBoundary() {
        let text = String(repeating: "alpha ", count: 40)
        let line = ErrorPresentation.menuLine(text)
        XCTAssertTrue(line.text.hasSuffix("alpha\u{2026}"), line.text)
    }

    func testAMultiLineTextShowsItsFirstLineAndOffersTheRest() {
        let line = ErrorPresentation.menuLine("Error: could not connect\nTry again in a minute.")
        XCTAssertEqual(line.text, "Error: could not connect")
        XCTAssertTrue(line.isSummary, "a second line exists, so Show Details has something to show")
    }

    func testEmptyAndBlankTextProducesNoLine() {
        XCTAssertEqual(ErrorPresentation.menuLine("").text, "")
        XCTAssertFalse(ErrorPresentation.menuLine("   \n \t ").isSummary)
    }

    // MARK: full text for a window

    func testTheWholeTextKeepsEveryWordAndNormalisesNewlines() {
        let text = ErrorPresentation.fullText("line one\r\nline two\rline three\u{0}\n")
        XCTAssertEqual(text, "line one\nline two\nline three")
    }

    func testTheWholeTextIsNeverShortened() {
        for item in cases {
            let full = ErrorPresentation.fullText(item.input)
            // Every non-control, non-space character survives.
            let kept = item.input.filter { !$0.isWhitespace && !($0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }) }
            XCTAssertEqual(full.filter { !$0.isWhitespace }, kept, item.name)
        }
    }

    func testAVeryLongWordIsStillWhole() {
        let word = String(repeating: "x", count: 5000)
        XCTAssertEqual(ErrorPresentation.fullText(word).count, 5000)
    }

    // MARK: the sign-in window

    func testAFailedSignInPhaseIsRecognisedSoTheWindowCanGiveItsSpaceToTheReason() {
        XCTAssertTrue(SignInPhase.failed("x").isFailure)
        XCTAssertFalse(SignInPhase.waiting.isFailure)
        XCTAssertFalse(SignInPhase.authorized.isFailure)
        XCTAssertFalse(SignInPhase.starting.isFailure)
    }

    @MainActor
    func testTheSignInFailureViewCarriesTheWholeSentence() {
        let view = SignInFailureView(message: incidentSentence)
        XCTAssertEqual(ErrorPresentation.fullText(view.message), incidentSentence)
    }

    // MARK: the details a menu offers

    @MainActor
    func testAShortenedErrorGivesTheMenuAShowDetailsItemWithTheWholeText() {
        let store = StateStore()
        store.cliStatus = CLIStatus(schemaVersion: 1, authenticated: true, accountId: "acct-example", companyName: nil,
                                    vpnAccountId: nil, vpnAccountMismatch: nil, vpnRunning: nil, authError: nil,
                                    sessionExpired: nil, authErrorKind: nil)
        store.errorMessage = incidentSentence
        let layout = MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                                     loginItemError: nil, now: Date())
        let shown = layout.item("status.error")?.title ?? ""
        XCTAssertLessThanOrEqual(shown.count, limit)
        XCTAssertNotEqual(shown, incidentSentence)
        XCTAssertNotNil(layout.item("details"))
        XCTAssertEqual(layout.details, incidentSentence)
    }

    @MainActor
    func testAShortErrorHasNoShowDetails() {
        let store = StateStore()
        store.errorMessage = "the VPN daemon is not answering"
        let layout = MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                                     loginItemError: nil, now: Date())
        XCTAssertEqual(layout.item("status.error")?.title, "the VPN daemon is not answering")
        XCTAssertNil(layout.item("details"))
        XCTAssertNil(layout.details)
    }

    @MainActor
    func testSeveralShortenedTextsShareOneDetailsItem() {
        let store = StateStore()
        store.errorMessage = incidentSentence
        store.noticeMessage = String(repeating: "notice ", count: 40)
        let layout = MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                                     loginItemError: String(repeating: "login item ", count: 20), now: Date())
        XCTAssertEqual(layout.items.filter { $0.action == .showDetails }.count, 1)
        XCTAssertEqual(layout.details?.components(separatedBy: "\n\n").count, 3)
    }

    // MARK: pending DNS (item 5)

    @MainActor
    private func connectedStore(dns: VPNDns?) -> StateStore {
        let store = StateStore()
        store.cliStatus = CLIStatus(schemaVersion: 1, authenticated: true, accountId: "acct-example", companyName: nil,
                                    vpnAccountId: nil, vpnAccountMismatch: nil, vpnRunning: true, authError: nil,
                                    sessionExpired: nil, authErrorKind: nil)
        store.vpnStatus = VPNStatus(
            schemaVersion: 1, running: true, accountId: "acct-example",
            session: VPNSession(present: true, expiresAt: Date().addingTimeInterval(20 * 3600), loginRequired: false),
            clusters: MenuStateMatrixTests.clusters(.one), lastPollError: nil, interface: nil, address: nil,
            dns: dns, version: nil)
        return store
    }

    @MainActor
    func testPendingDNSIsOneCalmLineAndNotAnError() {
        let store = connectedStore(dns: VPNDns(available: false, mode: "resolver-files",
                                               error: "Cluster names are still being applied by macOS.", pending: true))
        XCTAssertTrue(store.dnsPending)
        XCTAssertNil(store.dnsFailure, "pending must never read as a failure")
        XCTAssertEqual(store.menuBarState, .connected, "pending must not turn the icon to attention")
        let layout = MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                                     loginItemError: nil, now: Date())
        let line = layout.item("status.dns-pending")?.title
        XCTAssertEqual(line, "Connected. Cluster names are still being applied by macOS")
        for word in ["error", "fail", "cannot", "could not"] {
            XCTAssertFalse((line ?? "").localizedCaseInsensitiveContains(word), "the pending line says \"\(word)\"")
        }
        XCTAssertNil(layout.item("status.dns-failure"))
        XCTAssertNil(layout.item("status.error"))
        XCTAssertNil(layout.item("details"))
    }

    @MainActor
    func testPendingDNSIsNotClaimedWhenThereIsNoTunnel() {
        let store = connectedStore(dns: VPNDns(available: false, mode: nil, error: "pending", pending: true))
        store.vpnStatus = VPNStatus(
            schemaVersion: 1, running: false, accountId: nil, session: VPNSession(present: false, expiresAt: nil, loginRequired: false),
            clusters: [], lastPollError: nil, interface: nil, address: nil,
            dns: VPNDns(available: false, mode: nil, error: "pending", pending: true), version: nil)
        XCTAssertFalse(store.dnsPending, "\"Connected.\" would be a claim about a tunnel that is down")
    }

    @MainActor
    func testADNSFailureShowsTheCLIsOwnSentenceAndTurnsTheIconToAttention() {
        let store = connectedStore(dns: VPNDns(available: false, mode: "resolver-files",
                                               error: "could not write the resolver file: permission denied"))
        XCTAssertFalse(store.dnsPending)
        XCTAssertEqual(store.dnsFailure, "could not write the resolver file: permission denied")
        XCTAssertEqual(store.menuBarState, .attention)
        let layout = MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                                     loginItemError: nil, now: Date())
        XCTAssertEqual(layout.item("status.dns-failure")?.title, "could not write the resolver file: permission denied")
    }

    @MainActor
    func testAReleasedCLIWithoutTheFieldShowsNothingAboutDNS() {
        let store = connectedStore(dns: VPNDns(available: true, mode: "resolver-files", error: nil))
        XCTAssertFalse(store.dnsPending)
        XCTAssertNil(store.dnsFailure)
        let layout = MenuModel.build(store: store, launchAtLogin: false, connectAutomatically: false,
                                     loginItemError: nil, now: Date())
        XCTAssertNil(layout.item("status.dns-pending"))
        XCTAssertNil(layout.item("status.dns-failure"))
    }

    @MainActor
    func testADNSUnavailableWithNoSentenceIsNotAnErrorLine() {
        // A service without DNS support says available:false and nothing else. That is not news.
        let store = connectedStore(dns: VPNDns(available: false, mode: nil, error: nil))
        XCTAssertNil(store.dnsFailure)
        XCTAssertEqual(store.menuBarState, .connected)
    }
}

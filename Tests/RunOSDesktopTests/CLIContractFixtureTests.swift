import XCTest
@testable import RunOSDesktop

/*
 The CLI contract, pinned by golden outputs.

 Every CLI output this app decodes has a family of files under Fixtures/: the normal answer, the
 signed-out and tunnel-down answers, the pending-DNS answer, and a set of hostile variants (null
 for each optional and list field, missing fields, unknown fields, a bumped schemaVersion, wrong
 types, empty strings, an empty object, truncated output, text where JSON should be).

 THE RULE EACH FILE IS HELD TO: the app decodes it into a sensible state, or it reports a clear
 failure. It never decodes into a blank state without saying so. A failure must carry a headline,
 a reason in plain words, and none of Foundation's generic "data couldn't be read" text.

 The fixtures are anonymised: example.test names and 192.0.2.0/24 addresses only.
 (FCR 1730: `"clusters": null` once blanked the whole menu.)
*/
final class CLIContractFixtureTests: XCTestCase {

    // MARK: harness

    private enum Expect<T> {
        case decodes((T) throws -> Void)
        case fails(reasonContains: String)
    }

    private func check<T: Decodable>(
        _ type: T.Type, family: String, what: String, cases: [String: Expect<T>],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let stems = try Fixtures.stems(in: family)
        XCTAssertEqual(Set(stems), Set(cases.keys),
                       "\(family): every fixture needs an expectation and every expectation a fixture",
                       file: file, line: line)
        for (stem, expectation) in cases.sorted(by: { $0.key < $1.key }) {
            let data = try Fixtures.data(family, stem)
            let outcome = CLIReading.decode(type, from: data, what: what)
            switch (outcome, expectation) {
            case (.success(let value), .decodes(let verify)):
                do { try verify(value) } catch { XCTFail("\(family)/\(stem): \(error)", file: file, line: line) }
            case (.failure(let failure), .fails(let fragment)):
                XCTAssertEqual(failure.headline, "Cannot read \(what)", "\(family)/\(stem)", file: file, line: line)
                XCTAssertTrue(failure.reason.localizedCaseInsensitiveContains(fragment),
                              "\(family)/\(stem): reason was \"\(failure.reason)\"", file: file, line: line)
                XCTAssertFalse(failure.reason.contains("couldn\u{2019}t be read") || failure.reason.contains("couldn't be read"),
                               "\(family)/\(stem): Foundation's generic text leaked: \(failure.reason)", file: file, line: line)
                XCTAssertFalse(failure.reason.isEmpty, "\(family)/\(stem)", file: file, line: line)
            case (.success, .fails):
                XCTFail("\(family)/\(stem) decoded but a clear failure was expected", file: file, line: line)
            case (.failure(let failure), .decodes):
                XCTFail("\(family)/\(stem) should decode but failed: \(failure.summary)", file: file, line: line)
            }
        }
    }

    // MARK: vpn status

    func testVPNStatusFixtures() throws {
        let utc = Date(timeIntervalSince1970: 1_793_093_400) // 2026-10-27T09:30:00Z
        try check(VPNStatus.self, family: "vpn-status", what: "the VPN status", cases: [
            "normal-connected": .decodes { v in
                XCTAssertTrue(v.running)
                XCTAssertEqual(v.clusters.count, 1)
                XCTAssertTrue(v.session.present)
                XCTAssertEqual(v.dns?.available, true)
                XCTAssertNil(v.dns?.pending)
                XCTAssertEqual(v.version, "1.22.2")
                XCTAssertEqual(v.clusters[0].rxBytes, 1024)
                XCTAssertTrue(v.hasWorkingConnection)
            },
            "vpn-down": .decodes { v in
                XCTAssertFalse(v.running)
                XCTAssertTrue(v.clusters.isEmpty)
                XCTAssertNil(v.dns)
            },
            "signed-out-session-ended": .decodes { v in XCTAssertTrue(v.session.loginRequired) },
            "tunnel-up-session-expired": .decodes { v in
                XCTAssertTrue(v.running)
                XCTAssertTrue(v.session.loginRequired)
                XCTAssertNotNil(v.session.expiresAt)
            },
            "many-clusters-one-dead": .decodes { v in
                XCTAssertEqual(v.clusters.count, 3)
                XCTAssertEqual(v.deadConnections.map(\.cid), ["c-example2"])
                XCTAssertEqual(v.connectableClusters.count, 3)
                XCTAssertTrue(v.hasWorkingConnection)
            },
            "pending-dns": .decodes { v in
                XCTAssertEqual(v.dns?.pending, true)
                XCTAssertEqual(v.dns?.error, "Cluster names are still being applied by macOS.")
            },
            "failed-dns": .decodes { v in
                XCTAssertNil(v.dns?.pending)
                XCTAssertEqual(v.dns?.available, false)
                XCTAssertTrue(v.dns?.error?.contains("permission denied") == true)
            },
            "released-cli-without-dns-pending": .decodes { v in XCTAssertNil(v.dns?.pending) },
            "service-build-differs": .decodes { v in XCTAssertEqual(v.version, "1.20.0") },
            "hostile-null-clusters": .decodes { v in XCTAssertTrue(v.clusters.isEmpty) },
            "hostile-missing-clusters": .decodes { v in XCTAssertTrue(v.clusters.isEmpty) },
            "hostile-null-every-optional": .decodes { v in
                XCTAssertNil(v.schemaVersion)
                XCTAssertNil(v.dns)
                XCTAssertNil(v.version)
                XCTAssertTrue(v.clusters[0].peeredWith.isEmpty)
                XCTAssertFalse(v.clusters[0].peerUp)
                XCTAssertNil(v.clusters[0].rxBytes)
                XCTAssertNil(v.session.expiresAt)
            },
            "hostile-missing-every-optional": .decodes { v in
                XCTAssertTrue(v.session.present)
                XCTAssertEqual(v.clusters[0].name, "Example Cluster")
            },
            "hostile-unknown-fields": .decodes { v in XCTAssertEqual(v.clusters.count, 1) },
            "hostile-schema-bumped": .decodes { v in XCTAssertEqual(v.schemaVersion, 99) },
            "hostile-number-as-string": .decodes { v in
                XCTAssertEqual(v.schemaVersion, 1)
                XCTAssertEqual(v.clusters[0].rxBytes, 1024)
                XCTAssertEqual(v.clusters[0].txBytes, 2048)
            },
            "hostile-running-as-string": .fails(reasonContains: "running"),
            "hostile-version-as-number": .decodes { v in XCTAssertNil(v.version) },
            "hostile-empty-strings": .decodes { v in
                XCTAssertEqual(MenuPresentation.clusterLabel(v.clusters[0]), "c-example1",
                               "an empty name falls back to the id")
            },
            "hostile-empty-object": .fails(reasonContains: "running"),
            "hostile-session-missing": .fails(reasonContains: "session"),
            "hostile-clusters-is-an-object": .fails(reasonContains: "clusters"),
            "hostile-cluster-without-cid": .fails(reasonContains: "cid"),
            "hostile-fractional-seconds-date": .decodes { v in
                XCTAssertEqual(try XCTUnwrap(v.session.expiresAt).timeIntervalSince(utc), 0.123, accuracy: 0.01)
            },
            "hostile-offset-date": .decodes { v in XCTAssertEqual(v.session.expiresAt, utc) },
            "hostile-unparseable-date": .decodes { v in
                XCTAssertTrue(v.session.present)
                XCTAssertNil(v.session.expiresAt)
            },
            "hostile-zero-handshake": .decodes { v in
                XCTAssertEqual(StatsFormatting.handshake(v.clusters[0].lastHandshake), "never")
            },
            "hostile-truncated": .fails(reasonContains: "cut off"),
            "hostile-noise-only": .fails(reasonContains: "text instead of JSON"),
            "hostile-noise-before-json": .decodes { v in XCTAssertTrue(v.running) },
            "hostile-empty-output": .fails(reasonContains: "nothing"),
            "hostile-html-error-page": .fails(reasonContains: "text instead of JSON"),
            "hostile-json-array": .fails(reasonContains: "wrong kind"),
            "hostile-json-null": .fails(reasonContains: "wrong kind"),
        ])
    }

    // MARK: status

    func testStatusFixtures() throws {
        try check(CLIStatus.self, family: "status", what: "the RunOS status", cases: [
            "normal-signed-in": .decodes { s in
                XCTAssertTrue(s.authenticated)
                XCTAssertEqual(s.accountId, "acct-example")
                XCTAssertEqual(s.companyName, "Example Co")
            },
            "signed-out-rejected": .decodes { s in
                XCTAssertFalse(s.authenticated)
                XCTAssertEqual(s.authErrorKind, "rejected")
            },
            "signed-out-network": .decodes { s in XCTAssertEqual(s.authErrorKind, "network") },
            "signed-out-session-aged-out": .decodes { s in XCTAssertEqual(s.sessionExpired, true) },
            "vpn-account-mismatch": .decodes { s in XCTAssertEqual(s.vpnAccountMismatch, true) },
            "hostile-null-every-optional": .decodes { s in
                XCTAssertTrue(s.authenticated)
                XCTAssertNil(s.accountId)
                XCTAssertNil(s.sessionExpired)
            },
            "hostile-missing-every-optional": .decodes { s in XCTAssertTrue(s.authenticated) },
            "hostile-unknown-fields": .decodes { s in XCTAssertTrue(s.authenticated) },
            "hostile-schema-bumped": .decodes { s in XCTAssertEqual(s.schemaVersion, 99) },
            "hostile-number-as-string": .decodes { s in
                XCTAssertEqual(s.schemaVersion, 1)
                XCTAssertNil(s.accountId, "a number is not an account id and must not become one")
            },
            "hostile-authenticated-as-string": .fails(reasonContains: "authenticated"),
            "hostile-authenticated-null": .fails(reasonContains: "authenticated"),
            "hostile-empty-strings": .decodes { s in XCTAssertEqual(s.accountId, "") },
            "hostile-empty-object": .fails(reasonContains: "authenticated"),
            "hostile-truncated": .fails(reasonContains: "cut off"),
            "hostile-noise-only": .fails(reasonContains: "text instead of JSON"),
            "hostile-noise-before-json": .decodes { s in XCTAssertTrue(s.authenticated) },
            "hostile-empty-output": .fails(reasonContains: "nothing"),
        ])
    }

    // MARK: accounts

    func testUserAccountsFixtures() throws {
        try check(UserAccountsResult.self, family: "user-accounts", what: "the account list", cases: [
            "normal-two-accounts": .decodes { r in
                XCTAssertEqual(r.accounts.map(\.aid), ["acct-example", "acct-other"])
                XCTAssertEqual(r.accounts[1].label, "Other Co")
            },
            "single-account": .decodes { r in XCTAssertEqual(r.accounts.count, 1) },
            "empty-list": .decodes { r in XCTAssertTrue(r.accounts.isEmpty) },
            "hostile-null-accounts": .decodes { r in XCTAssertTrue(r.accounts.isEmpty) },
            "hostile-missing-accounts": .decodes { r in XCTAssertTrue(r.accounts.isEmpty) },
            "hostile-entry-null-optionals": .decodes { r in XCTAssertEqual(r.accounts[0].label, "acct-example") },
            "hostile-entry-missing-optionals": .decodes { r in XCTAssertEqual(r.accounts[0].label, "acct-example") },
            "hostile-entry-without-aid": .fails(reasonContains: "aid"),
            "hostile-unknown-fields": .decodes { r in XCTAssertEqual(r.accounts.count, 1) },
            "hostile-schema-bumped": .decodes { r in XCTAssertEqual(r.accounts.count, 1) },
            "hostile-isdefault-as-string": .fails(reasonContains: "isDefault"),
            "hostile-empty-strings": .decodes { r in XCTAssertEqual(r.accounts[0].label, "acct-example") },
            "hostile-empty-object": .decodes { r in XCTAssertTrue(r.accounts.isEmpty) },
            "hostile-truncated": .fails(reasonContains: "cut off"),
            "hostile-noise-only": .fails(reasonContains: "text instead of JSON"),
            "hostile-empty-output": .fails(reasonContains: "nothing"),
        ])
    }

    // MARK: update check

    func testUpdateCheckFixtures() throws {
        try check(UpdateCheck.self, family: "update-check", what: "the update check", cases: [
            "update-waiting": .decodes { c in
                XCTAssertTrue(c.anyAvailable)
                XCTAssertTrue(c.verdictKnown)
            },
            "up-to-date": .decodes { c in
                XCTAssertFalse(c.anyAvailable)
                XCTAssertTrue(c.verdictKnown)
            },
            "desktop-not-installed": .decodes { c in
                XCTAssertNil(c.desktop)
                XCTAssertTrue(c.verdictKnown)
            },
            "released-cli-without-verdict": .decodes { c in
                XCTAssertFalse(c.anyAvailable)
                XCTAssertFalse(c.verdictKnown, "an unknown must stay unknown so Update RunOS stays clickable")
            },
            "hostile-null-every-optional": .decodes { c in
                XCTAssertFalse(c.verdictKnown)
                XCTAssertNil(c.desktop)
            },
            "hostile-missing-every-optional": .decodes { c in XCTAssertFalse(c.verdictKnown) },
            "hostile-unknown-fields": .decodes { c in XCTAssertTrue(c.anyAvailable) },
            "hostile-schema-bumped": .decodes { c in XCTAssertTrue(c.anyAvailable) },
            "hostile-available-as-string": .decodes { c in
                XCTAssertFalse(c.verdictKnown, "\"true\" is not a verdict; it must not light the badge")
                XCTAssertFalse(c.anyAvailable)
            },
            "hostile-empty-strings": .decodes { c in XCTAssertFalse(c.anyAvailable) },
            "hostile-empty-object": .fails(reasonContains: "cli"),
            "hostile-cli-null": .fails(reasonContains: "cli"),
            "hostile-truncated": .fails(reasonContains: "cut off"),
            "hostile-noise-only": .fails(reasonContains: "text instead of JSON"),
            "hostile-empty-output": .fails(reasonContains: "nothing"),
        ])
    }

    // MARK: update

    func testUpdateResultFixtures() throws {
        try check(UpdateResult.self, family: "update", what: "the update result", cases: [
            "cli-updated": .decodes { r in XCTAssertTrue(r.cli.updated) },
            "nothing-to-update": .decodes { r in
                XCTAssertFalse(r.cli.updated)
                XCTAssertEqual(r.desktop?.updated, false)
            },
            "desktop-updated": .decodes { r in XCTAssertEqual(r.desktop?.updated, true) },
            "hostile-null-every-optional": .decodes { r in
                XCTAssertTrue(r.cli.updated)
                XCTAssertNil(r.desktop)
            },
            "hostile-missing-every-optional": .decodes { r in XCTAssertFalse(r.cli.updated) },
            "hostile-unknown-fields": .decodes { r in XCTAssertTrue(r.cli.updated) },
            "hostile-schema-bumped": .decodes { r in XCTAssertTrue(r.cli.updated) },
            "hostile-number-as-string": .decodes { r in XCTAssertTrue(r.cli.updated) },
            "hostile-updated-as-string": .fails(reasonContains: "updated"),
            "hostile-empty-strings": .decodes { r in XCTAssertTrue(r.cli.updated) },
            "hostile-empty-object": .fails(reasonContains: "cli"),
            "hostile-truncated": .fails(reasonContains: "cut off"),
            "hostile-noise-only": .fails(reasonContains: "text instead of JSON"),
            "hostile-empty-output": .fails(reasonContains: "nothing"),
        ])
    }

    // MARK: nodes list (Connection Status window)

    func testNodesListFixtures() throws {
        try check(DiagnosticsNodeList.self, family: "nodes-list", what: "the node list", cases: [
            "normal": .decodes { l in
                XCTAssertEqual(l.nodes.count, 2)
                XCTAssertEqual(l.nodes[0].label, "node-a")
                XCTAssertEqual(l.nodes[1].label, "node-b.example.test", "an empty name falls back to the hostname")
            },
            "empty-list": .decodes { l in XCTAssertTrue(l.nodes.isEmpty) },
            "hostile-null-nodes": .decodes { l in XCTAssertTrue(l.nodes.isEmpty) },
            "hostile-missing-nodes": .decodes { l in XCTAssertTrue(l.nodes.isEmpty) },
            "hostile-node-null-fields": .decodes { l in XCTAssertEqual(l.nodes[0].label, "node") },
            "hostile-node-empty-object": .decodes { l in XCTAssertEqual(l.nodes[0].label, "node") },
            "hostile-unknown-fields": .decodes { l in XCTAssertEqual(l.nodes[0].vpnIp, "192.0.2.21") },
            "hostile-number-as-string": .decodes { l in XCTAssertNil(l.nodes[0].vpnIp) },
            "hostile-nodes-is-a-string": .fails(reasonContains: "nodes"),
            "hostile-truncated": .fails(reasonContains: "cut off"),
            "hostile-noise-only": .fails(reasonContains: "text instead of JSON"),
            "hostile-empty-output": .fails(reasonContains: "nothing"),
        ])
    }

    // MARK: version text

    func testVersionFixtures() throws {
        let expectations: [String: CLIVersionCompatibility] = [
            "release": .supported, "release-with-v": .supported, "release-candidate": .supported,
            "development": .development, "development-bare": .development,
            "outdated": .outdated, "crlf": .supported, "padded": .supported,
            "hostile-sentence": .invalid, "hostile-empty": .invalid, "hostile-two-lines": .invalid,
            "hostile-two-parts": .invalid, "hostile-non-numeric": .invalid, "hostile-html": .invalid,
        ]
        XCTAssertEqual(Set(try Fixtures.stems(in: "version")), Set(expectations.keys))
        for (stem, expected) in expectations.sorted(by: { $0.key < $1.key }) {
            let text = try Fixtures.text("version", stem).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(VersionComparator.compatibility(text, minimum: "1.15.0"), expected, "version/\(stem)")
        }
    }

    // MARK: login events

    func testLoginEventFixtures() throws {
        let expectations: [String: (SignInEvent?) -> Bool] = [
            "device-code": { $0 == .deviceCode(id: "ABCD-1234", url: "https://console.example.test/device?code=ABCD-1234") },
            "browser-opened": { $0 == .browserOpened(true) },
            "pending": { $0 == .pending },
            // The CLI sends notices that Desktop does not draw; ignoring one must not break the flow.
            "notice": { $0 == nil },
            "authorized": { $0 == .authorized },
            "error": { $0 == .failed(reason: "expired", message: "The code expired. Start again.") },
            // Anything this build cannot use is ignored, never a crash and never a wrong event.
            "hostile-unknown-event": { $0 == nil },
            "hostile-device-code-without-url": { $0 == nil },
            "hostile-device-code-nulls": { $0 == nil },
            "hostile-device-code-empty-strings": { $0 == nil },
            "hostile-error-without-message": { $0 == .failed(reason: "failed", message: "Sign in failed.") },
            "hostile-error-message-number": { $0 == .failed(reason: "failed", message: "Sign in failed.") },
            "hostile-truncated": { $0 == nil },
            "hostile-noise": { $0 == nil },
            "hostile-empty-line": { $0 == nil },
            "hostile-event-as-number": { $0 == nil },
        ]
        XCTAssertEqual(Set(try Fixtures.stems(in: "login-events")), Set(expectations.keys))
        for (stem, verify) in expectations.sorted(by: { $0.key < $1.key }) {
            let line = try Fixtures.text("login-events", stem)
            XCTAssertTrue(verify(SignInEvent.parse(line)), "login-events/\(stem): \(String(describing: SignInEvent.parse(line)))")
        }
    }

    // MARK: failing commands

    func testCLIErrorFixturesAreClassifiedForThePerson() throws {
        let missing: [String: Bool] = [
            "service-not-installed": true, "daemon-not-answering": false,
            "permission-denied-service-running": false, "older-service": false, "long-dns-error": false,
        ]
        XCTAssertEqual(Set(try Fixtures.stems(in: "cli-errors")), Set(missing.keys))
        for (stem, isMissing) in missing.sorted(by: { $0.key < $1.key }) {
            let text = try Fixtures.text("cli-errors", stem).trimmingCharacters(in: .whitespacesAndNewlines)
            let error = CLIExecutionError(exitCode: 1, message: text)
            XCTAssertEqual(VPNService.isMissing(error), isMissing, "cli-errors/\(stem)")
        }
    }

    // MARK: no fixture may hold a real identifier

    func testFixturesUseOnlyDocumentationNamesAndAddresses() throws {
        let addressPattern = try NSRegularExpression(pattern: #"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b"#)
        let families = try FileManager.default.contentsOfDirectory(atPath: try Fixtures.root.path)
        // A version string is dotted numbers and not an address, so that family is not scanned.
        for family in families.sorted() where family != "version" {
            for stem in try Fixtures.stems(in: family) {
                let text = try Fixtures.text(family, stem)
                let range = NSRange(text.startIndex..., in: text)
                for match in addressPattern.matches(in: text, range: range) {
                    let first = (text as NSString).substring(with: match.range(at: 1))
                    let second = (text as NSString).substring(with: match.range(at: 2))
                    let third = (text as NSString).substring(with: match.range(at: 3))
                    XCTAssertTrue(first == "192" && second == "0" && third == "2",
                                  "\(family)/\(stem) holds an address outside 192.0.2.0/24")
                }
                XCTAssertFalse(text.contains("runos.com"), "\(family)/\(stem) names a real host")
            }
        }
    }
}

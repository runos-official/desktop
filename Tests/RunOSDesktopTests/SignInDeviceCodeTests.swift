import AppKit
import XCTest
@testable import RunOSDesktop

/*
 The Console no longer fills the device code in for the person: they type it on the approval page.
 The window therefore has to make the code easy to take. These tests use a private pasteboard so a
 test run never overwrites what the person has on their real clipboard.
*/
final class SignInDeviceCodeTests: XCTestCase {

    @MainActor
    private func model() -> SignInRunner {
        SignInRunner(runner: nil, purpose: .signIn, onFinished: {})
    }

    private func privatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("runos-desktop-test-\(UUID().uuidString)"))
    }

    @MainActor
    func testCopyDeviceCodePutsExactlyTheCodeOnThePasteboard() {
        let sut = model()
        sut.apply(.deviceCode(id: "ABCD-EFGH", url: "https://console.example.test/device"))
        let board = privatePasteboard()

        sut.copyDeviceCode(to: board)

        XCTAssertEqual(board.string(forType: .string), "ABCD-EFGH")
        XCTAssertTrue(sut.copiedCode)
    }

    @MainActor
    func testNothingIsCopiedBeforeACodeArrives() {
        let sut = model()
        let board = privatePasteboard()
        board.clearContents()
        board.setString("something the person copied", forType: .string)

        sut.copyDeviceCode(to: board)

        XCTAssertEqual(board.string(forType: .string), "something the person copied")
        XCTAssertFalse(sut.copiedCode)
    }

    /// A new code is a new thing to copy. "Copied" must not keep claiming the old one is on the clipboard.
    @MainActor
    func testACopiedMarkDoesNotSurviveANewCode() {
        let sut = model()
        sut.apply(.deviceCode(id: "AAAA-AAAA", url: "https://console.example.test/device"))
        sut.copyDeviceCode(to: privatePasteboard())
        XCTAssertTrue(sut.copiedCode)

        sut.apply(.deviceCode(id: "BBBB-BBBB", url: "https://console.example.test/device"))

        XCTAssertFalse(sut.copiedCode)
    }
}

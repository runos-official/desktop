import XCTest
@testable import RunOSDesktop

/*
 While a sign-in finishes the menu showed "Finishing sign in…" twice: once as the greyed status line
 at the top and once as the label of the Sign In button, which carries the operation text too. A
 person reads two lines as two sign-ins running, or as something stuck (FCR 1726). The status line
 is only for an operation no button already says.
*/
final class MenuOperationLineTests: XCTestCase {

    func testNoStatusLineWhenTheSignInButtonAlreadySaysIt() {
        XCTAssertFalse(MenuPresentation.showsOperationLine(
            operationMessage: "Finishing sign in…", signInButtonShown: true, renewButtonShown: false))
    }

    func testNoStatusLineWhenTheRenewButtonAlreadySaysIt() {
        XCTAssertFalse(MenuPresentation.showsOperationLine(
            operationMessage: "Renewing VPN session…", signInButtonShown: false, renewButtonShown: true))
    }

    func testStatusLineWhenNoButtonCarriesTheOperation() {
        XCTAssertTrue(MenuPresentation.showsOperationLine(
            operationMessage: "Installing the RunOS VPN service…", signInButtonShown: false, renewButtonShown: false))
    }

    func testNoStatusLineWithoutAnOperation() {
        XCTAssertFalse(MenuPresentation.showsOperationLine(
            operationMessage: nil, signInButtonShown: false, renewButtonShown: false))
        XCTAssertFalse(MenuPresentation.showsOperationLine(
            operationMessage: "", signInButtonShown: false, renewButtonShown: false))
    }
}

import XCTest
@testable import RunOSDesktop

/*
 Renewing the VPN session is the same command as connecting (`vpn up` mints a fresh 24 hour session,
 and asks for a browser check first when the last sign-in is older than five minutes). What differs
 is what the window and the menu say, because a person who is already connected and clicks Renew must
 not be told that they are connecting.
*/
final class SignInRenewTests: XCTestCase {

    func testRenewRunsTheSameCommandAsConnect() {
        XCTAssertEqual(SignInPurpose.renew.arguments, SignInPurpose.confirm.arguments)
    }

    func testRenewWaitsForADeviceCodeBeforeOpeningAWindow() {
        // A renew within five minutes of a sign-in needs no browser check, and a window that opens
        // and vanishes on its own reads as something having gone wrong.
        XCTAssertFalse(SignInPurpose.renew.presentsWindowImmediately)
    }

    func testRenewNeverSaysConnecting() {
        let words = [
            SignInPurpose.renew.windowTitle,
            SignInPurpose.renew.explanation,
            SignInPurpose.renew.busyMessage,
            SignInPurpose.renew.genericFailure,
            SignInPurpose.renew.approvedMessage,
        ]
        for sentence in words {
            XCTAssertFalse(sentence.localizedCaseInsensitiveContains("connect"), sentence)
        }
        XCTAssertEqual(SignInPurpose.renew.busyMessage, "Renewing VPN session…")
    }

    func testTheOtherPurposesKeepTheirWords() {
        XCTAssertEqual(SignInPurpose.confirm.approvedMessage, "Approved. Connecting…")
        XCTAssertEqual(SignInPurpose.signIn.approvedMessage, "Approved. Finishing sign in…")
    }

    func testRenewWarnsThatCancellingMeansSigningInAgain() {
        XCTAssertTrue(SignInPurpose.renew.explanation.contains("you will need to sign in again"))
    }
}

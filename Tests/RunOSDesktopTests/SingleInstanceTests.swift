import XCTest
@testable import RunOSDesktop

/*
 ONE ICON IN THE MENU BAR (FCR 1733).

 The operator saw two RunOS icons. A second copy of the app must wait a few seconds for the first
 to leave (the update flow ends the old copy and `runos desktop relaunch` opens the new one only
 AFTER the old process is gone, so the overlap is short or none) and then, if the other is still
 there, quit without a word. The decision is a pure function; the process query is a seam.
*/
final class SingleInstanceTests: XCTestCase {

    func testNoOtherCopyMeansProceedAtOnce() {
        XCTAssertEqual(SingleInstance.decision(otherCopies: 0, waited: 0, maxWait: 5), .proceed)
        XCTAssertEqual(SingleInstance.decision(otherCopies: 0, waited: 4.9, maxWait: 5), .proceed)
    }

    func testAnotherCopyMeansWaitUntilTheLimit() {
        XCTAssertEqual(SingleInstance.decision(otherCopies: 1, waited: 0, maxWait: 5), .wait)
        XCTAssertEqual(SingleInstance.decision(otherCopies: 2, waited: 4.99, maxWait: 5), .wait)
    }

    func testAnotherCopyAtTheLimitMeansQuit() {
        XCTAssertEqual(SingleInstance.decision(otherCopies: 1, waited: 5, maxWait: 5), .quit)
        XCTAssertEqual(SingleInstance.decision(otherCopies: 1, waited: 60, maxWait: 5), .quit)
    }

    func testAZeroWaitQuitsImmediatelyBesideAnotherCopy() {
        XCTAssertEqual(SingleInstance.decision(otherCopies: 1, waited: 0, maxWait: 0), .quit)
    }

    func testThisProcessIsNeverCountedAsAnotherCopy() {
        let others = SingleInstance.others(running: [100, 200, 300], excluding: 200, isAlive: { _ in true })
        XCTAssertEqual(others, [100, 300])
    }

    func testACopyThatHasExitedIsNotCounted() {
        let others = SingleInstance.others(running: [100, 300], excluding: 1, isAlive: { $0 == 300 })
        XCTAssertEqual(others, [300])
    }

    func testNothingRunningMeansNoOthers() {
        XCTAssertEqual(SingleInstance.others(running: [], excluding: 1, isAlive: { _ in true }), [])
    }

    private final class Clock: @unchecked Sendable {
        var slept: [TimeInterval] = []
        var polls = 0
    }

    func testTheOtherCopyLeavingDuringTheWaitLetsThisOneProceed() {
        // The update relaunch: the old copy is still exiting when the new one starts.
        let clock = Clock()
        let environment = SingleInstance.Environment(
            otherCopies: { clock.polls += 1; return clock.polls <= 3 ? 1 : 0 },
            sleep: { clock.slept.append($0) })
        XCTAssertTrue(SingleInstance.shouldProceed(maxWait: 5, step: 0.25, environment: environment))
        XCTAssertEqual(clock.slept, [0.25, 0.25, 0.25])
    }

    func testNoOtherCopyProceedsWithoutSleeping() {
        let clock = Clock()
        let environment = SingleInstance.Environment(otherCopies: { 0 }, sleep: { clock.slept.append($0) })
        XCTAssertTrue(SingleInstance.shouldProceed(environment: environment))
        XCTAssertTrue(clock.slept.isEmpty)
    }

    func testACopyThatNeverLeavesMakesThisOneQuitAfterTheLimitAndNoLonger() {
        let clock = Clock()
        let environment = SingleInstance.Environment(otherCopies: { 1 }, sleep: { clock.slept.append($0) })
        XCTAssertFalse(SingleInstance.shouldProceed(maxWait: 2, step: 0.5, environment: environment))
        XCTAssertEqual(clock.slept.reduce(0, +), 2, accuracy: 0.001, "waits the limit, not longer")
        XCTAssertEqual(clock.slept.count, 4)
    }

    func testTwoCopiesStartingTogetherLeaveExactlyOne() {
        // Each sees the other. Both would wait and both quit, which is why the live query counts only
        // copies that are ALREADY running: here the one that is later in the list is the newcomer.
        let first = SingleInstance.others(running: [10, 20], excluding: 10, isAlive: { _ in true })
        XCTAssertEqual(first, [20])
    }

    func testTheLiveEnvironmentSeesNoOtherCopyOfAnUnknownBundle() {
        let environment = SingleInstance.liveEnvironment(bundleIdentifier: "test.example.no-such-app")
        XCTAssertEqual(environment.otherCopies(), 0)
    }

    func testTheGuardIsSkippedUnderTheTestRunner() {
        XCTAssertTrue(SingleInstance.isRunningTests(environment: ["XCTestConfigurationFilePath": "/x"]))
        XCTAssertFalse(SingleInstance.isRunningTests(environment: [:]))
    }
}

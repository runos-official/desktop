import AppKit
import Foundation

/*
 ONE ICON IN THE MENU BAR (FCR 1733).

 Two copies of the app put two RunOS icons in the menu bar, each polling the CLI and each able to
 start a sign-in beside the other. A copy that finds another already running waits a few seconds for
 it to leave and then, if it is still there, quits without a word.

 THE WAIT IS FOR THE UPDATE. After an update the old copy quits and `runos desktop relaunch --wait-pid`
 opens the new one once that process is gone, so the overlap is short or none; a few seconds covers
 the case where the old process is still tearing down. Without the wait the new copy would see the
 old one and quit, leaving NO copy running after an update.

 The decision and the wait are pure and take their process query as a seam, so both are tested
 without a second app. Only the query that asks the system is not.
*/
enum SingleInstance {
    enum Decision: Equatable { case proceed, wait, quit }

    /// Proceed when nobody else is running; otherwise wait until the limit, then quit.
    static func decision(otherCopies: Int, waited: TimeInterval, maxWait: TimeInterval) -> Decision {
        guard otherCopies > 0 else { return .proceed }
        return waited < maxWait ? .wait : .quit
    }

    struct Environment {
        /// How many OTHER live copies of this app are running right now.
        var otherCopies: () -> Int
        /// Pauses for the given seconds.
        var sleep: (TimeInterval) -> Void
    }

    /// Whether this copy should carry on. Blocks, up to `maxWait`, while another copy is running.
    static func shouldProceed(maxWait: TimeInterval = 5, step: TimeInterval = 0.25, environment: Environment) -> Bool {
        var waited: TimeInterval = 0
        while true {
            switch decision(otherCopies: environment.otherCopies(), waited: waited, maxWait: maxWait) {
            case .proceed: return true
            case .quit: return false
            case .wait:
                let pause = min(step, maxWait - waited)
                environment.sleep(pause)
                waited += pause
            }
        }
    }

    /// The pids that count as another copy: not this process, and still alive.
    static func others(running pids: [pid_t], excluding me: pid_t, isAlive: (pid_t) -> Bool) -> [pid_t] {
        pids.filter { $0 != me && isAlive($0) }
    }

    /// The query against the system. `kill(pid, 0)` is checked as well as NSRunningApplication,
    /// because the latter can lag a process that has already exited.
    static func liveEnvironment(bundleIdentifier: String) -> Environment {
        let me = ProcessInfo.processInfo.processIdentifier
        return Environment(
            otherCopies: {
                let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .filter { !$0.isTerminated }
                    .map(\.processIdentifier)
                return others(running: pids, excluding: me, isAlive: { kill($0, 0) == 0 || errno == EPERM }).count
            },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// The test runner launches this app as its host, often beside the installed copy. The guard
    /// must never quit that.
    static func isRunningTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}

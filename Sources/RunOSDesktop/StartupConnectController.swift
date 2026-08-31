import Combine
import Foundation

/*
 Whether the app brings the VPN up on its own, and WHEN it is allowed to.

 Reported 2026-08-31: "i have connect vpn at startup selected, but after logging in, it doesn't
 auto connect." It fired exactly once, in the app's init. On a machine that launches the app at
 login that is while the person is still signed out, so `vpn up --non-interactive` refused for want
 of an identity and nothing ever retried. The setting looked broken at the one moment it was most
 wanted, which is the first connect of the day.

 So it is not a startup setting. It means "connect when you can", and the moments it can are app
 start and a sign-in completing.

 It replaced the account submenu. Listing accounts was work the desktop did not need to do: what an
 account is for is decided when a person signs in, and picking one from a menu bar changed nothing
 they could see. Connecting the VPN without being asked is the thing they actually wanted from a
 menu bar app.

 Persisted, because the entire point is to act at a moment when nobody is watching. It defaults
 OFF: starting to bring up a tunnel on somebody's machine because they took an update is not a
 decision this app gets to make for them.
*/
enum AutoConnect {
    /// The menu label. It no longer says "at Startup", because that is what made the report read as
    /// a defect: a box promising a connection, ticked, with no connection.
    static let menuLabel = "Connect VPN Automatically"

    /*
     Whether a refresh has just seen the moment this setting exists for.

     A TRANSITION, not a state. "signed in and the tunnel is down" is also true one second after
     somebody clicks Disconnect, and acting on that would reconnect them over and over with no way
     to turn the VPN off short of turning the setting off first.

     `wasSignedIn` nil is the first observation of all, at app launch. The startup connect in the
     app's init owns that moment, and acting here as well would run two connects over each other.
    */
    static func shouldConnect(
        enabled: Bool,
        wasSignedIn: Bool?,
        isSignedIn: Bool,
        tunnelRunning: Bool
    ) -> Bool {
        guard enabled, isSignedIn, !tunnelRunning else { return false }
        return wasSignedIn == false
    }
}

@MainActor
final class StartupConnectController: ObservableObject {
    private static let key = "connectVPNAtStartup"

    private let defaults: UserDefaults
    @Published private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `bool(forKey:)` is false for an unset key, which is the default this wants.
        isEnabled = defaults.bool(forKey: Self.key)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
        isEnabled = enabled
    }
}

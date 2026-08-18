import Combine
import Foundation

/*
 Whether the VPN is brought up when the app starts, which on a machine that launches it at login
 means when the computer starts.

 It replaces the account submenu. Listing accounts was work the desktop did not need to do: what
 an account is for is decided when a person signs in, and picking one from a menu bar changed
 nothing they could see. Connecting the VPN without being asked is the thing they actually wanted
 from a menu bar app.

 Persisted, because the entire point is to act at a moment when nobody is watching. It defaults
 OFF: starting to bring up a tunnel on somebody's machine because they took an update is not a
 decision this app gets to make for them.
*/
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

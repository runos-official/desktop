# Changelog

## v0.3.0

- Sign In and Sign Out now sign you in and out. They ran `vpn up` and `vpn down`, which never touched the CLI's credentials, so inside this app "signed in" meant "has a VPN session". They run `runos login` and `runos logout`.
- A signed-out machine can be signed in from the app. `vpn up` resolves a credential before it does anything else, so on the one machine that most needed the button it exited at once and the window said "Sign in did not complete."
- Connecting no longer flashes a window at you. Clicking Connect always opened a modal headed "Confirm it's you", even though most connects happen while the sign-in is still fresh and need no confirmation at all, so it appeared and withdrew itself. The window now waits until there is a device code to show, and the menu says "Connecting VPN…" meanwhile.
- "Connect VPN at Startup" is now "Connect VPN Automatically", and it means it. It fired once, in the app's own startup, which on a machine that launches at login is while you are still signed out. It refused for want of an identity and never retried, so the setting looked broken at the one moment it was most wanted. It now also connects when a sign-in completes. A manual Disconnect still sticks.
- The VPN submenu says Disconnect, which is what it always did. Sign Out moved to the top level, where it ends your identity and takes the tunnel with it.
- A failure says why. The CLI's explanation was sent to `/dev/null`, so every failure after the browser authorised, the token exchange, the enrolment, the session mint, reached you as one generic sentence.
- The connected icon now needs a live session, not just a tunnel interface. An expired session leaves the interface up, so the menu bar claimed a working VPN over a path that dropped every packet.
- A network blip no longer asks you to sign in. A timeout reaching the sign-in service was indistinguishable from being signed out, and put a Sign In button in front of people whose session was fine.
- The app no longer moves the VPN to another account by itself. It could not work, because the device key and device id are both account-scoped, and it turned the VPN on for people who had not asked.

## v0.2.1

- Offer to install the RunOS VPN service when it is missing, instead of failing quietly. `runos desktop install` writes the app and not the root service that carries the tunnel, so a fresh machine could click Connect and see nothing happen at all.
- Ask for the administrator password through the standard macOS prompt, and pass the installing person's identity to the CLI, so the control socket belongs to a group they are actually in. Without it the service installed, started, and was unreachable by the person who installed it.
- Stop reporting every VPN failure as "sign in required". A missing service sent people to a browser to fix a daemon that was never installed.
- Stop discarding the CLI's explanation when reading VPN status. It was thrown away, so the menu showed "disconnected" and said nothing.
- Check every cluster at the same time in the Connection Status window, rather than one after another. An unreachable cluster used to make every cluster after it wait out its timeouts.

## v0.2.0

- Add a Sign In window that shows the device code, the verification link and live sign-in status.
- Open the browser from a button in the Sign In window, so the device code is readable first.
- Say "Signed out" in the menu, and disable the VPN controls, while a sign-in is owed.
- Light the menu-bar icon only when the connection works.
- Stop the status block indenting the rest of the menu.
- Show when the VPN session expires, in the VPN menu and, inside the last hour, in the status.
- Ask for a sign-in when the VPN session has expired, not only after an account switch.
- Report a failed ping as "no reply" instead of the whole of ping's output.
- Say "VPN session expired" in the Connection Status window rather than running tests that cannot pass.
- Keep the VPN session when a cluster is toggled off; only Sign Out ends it.
- Show tunnel and traffic statistics on the About panel.
- Add a last-hour traffic chart in five-minute buckets, with a total.
- Add a Connection Status window that pings the VPN server and every node, then resolves private DNS, one cluster at a time.
- Remove the peering hint line from the menu.

## v0.1.0

- Add the RunOS menu-bar application for macOS 15 and newer.
- Add account selection and VPN controls through the RunOS CLI.
- Add separate Apple Silicon and Intel release artifacts.
- Add checksum and build provenance verification.

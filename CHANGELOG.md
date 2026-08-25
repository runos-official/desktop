# Changelog

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

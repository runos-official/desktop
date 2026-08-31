import AppKit
import SwiftUI

enum MenuPresentation {
    /// The menu item that appears only while the VPN service is on a different build. Named for the
    /// action, because its PRESENCE is what says a restart is needed; the words do not have to
    /// carry that as well.
    static let vpnRestartTitle = "Restart VPN"

    static func clusterLabel(name: String, cid: String) -> String {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? cid : "\(displayName) (\(cid))"
    }

    /*
     The label a person reads in the menu, carrying the trouble when there is any.

     A dead connection used to render as an ordinary ticked toggle, which asserted a working tunnel
     over a cluster that routes nothing. The reason is the whole explanation, so it goes in the
     label rather than somewhere the person has to go looking.
     */
    /*
     THERE IS NO ACCOUNT-DIFFERENCE SENTENCE ANY MORE, and that is deliberate.

     `signInPrompt(account:)` lived here and named the account a sign-in was for, because the app
     tried to move the tunnel onto whichever account the CLI had switched to and sometimes could
     not. It no longer tries (FPL26 D3): the tunnel never outlives the identity that opened it, the
     CLI drops it when the identity changes, and the person connects the new account deliberately.
     With nothing happening behind their back there is nothing to explain, so the button says it
     all.
    */

    static func sessionExpiry(_ session: VPNSession?, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let session, session.present, !session.loginRequired, let expiresAt = session.expiresAt else {
            return nil
        }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let clock = formatter.string(from: expiresAt)

        if remaining >= 3600 {
            return "Session expires in \(Int(remaining) / 3600)h (\(clock))"
        }
        if remaining >= 60 {
            return "Session expires in \(Int(remaining) / 60)m (\(clock))"
        }
        return "Session expires in under a minute (\(clock))"
    }

    static func clusterLabel(_ cluster: VPNCluster) -> String {
        let base = clusterLabel(name: cluster.name, cid: cluster.cid)
        guard cluster.isDeadConnection else { return base }
        let reason = (cluster.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "\(base): not connected"
            : "\(base): not connected, \(reason)"
    }
}

struct MenuContentView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var startupConnect: StartupConnectController

    private var store: StateStore { coordinator.store }

    var body: some View {
        Group {
            Group {
                statusMessages
                vpnMenu
                Divider()
                actionItems
            }
            .disabled(store.isBusy)
            Divider()
            Button("Connection Status") {
                ConnectionStatusWindowController.shared.show(vpn: store.vpnStatus)
            }
            .disabled(store.vpnStatus?.running != true)
            Button("About RunOS Desktop") {
                AboutPresenter.live.show(AboutDetails(
                    desktopVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                    cliVersion: store.cliVersion,
                    accountId: store.activeAccountId,
                    companyName: store.cliStatus?.companyName,
                    vpn: store.vpnStatus,
                    trafficSlots: store.traffic.hourSlots(),
                    trafficTotal: store.traffic.lastHourTotal
                ))
            }
            Button("Quit RunOS Desktop") { NSApplication.shared.terminate(nil) }
        }
        .onAppear {
            coordinator.setMenuOpen(true)
            // The person can change this in System Settings, so the toggle is re-read rather than
            // remembered from launch. See LoginItemController.refresh.
            loginItem.refresh()
        }
        .onDisappear { coordinator.setMenuOpen(false) }
    }

    @ViewBuilder
    private var statusMessages: some View {
        // PLAIN TEXT, no `Label`, and that is the whole reason these read as they do.
        //
        // An icon in a menu item widens the leading column for EVERY item in the group, so one
        // Label here pushed the sign-in line, the Sign In button and the VPN submenu right, past
        // the checkmark column the rest of the menu aligns to. The menu then looked like two menus.
        // Nothing was gained for it: a four-item status block does not need iconography to be
        // read, and the icons were never load-bearing.
        if let operation = store.operationMessage {
            Text(operation)
        }
        /*
         THE SERVICE IS MISSING, which is a thing to install and not a thing to explain.

         Shown ABOVE the sign-in block because it is the more fundamental gap: signing in cannot
         help a machine with no daemon to carry the tunnel. `runos desktop install` never writes it,
         so this is the ordinary state of a fresh machine.
        */
        if store.vpnServiceMissing {
            Text("The RunOS VPN service is not installed, so the VPN cannot connect.")
            Button("Install VPN Service…") {
                coordinator.installVPNService()
            }
        }
        if store.signInRequired {
            /*
             NO LINE ABOVE THE BUTTON when the session has simply ended.

             "You are currently signed out." over a button reading "Sign In" says the same thing
             twice, and the first time in greyed-out text that cannot be acted on. The button IS
             the statement: an app offering to sign you in is not one you are signed in to.

             The button now runs `runos login`, which is the only command in this app that
             establishes an identity. It used to run `vpn up`, which RESOLVES a credential before it
             does anything else and therefore exited immediately on the one machine that needed this
             button most: a signed-out one (reported 2026-08-28).
            */
            Button("Sign In") {
                coordinator.beginSignIn(purpose: .signIn)
            }
        }
        // Inside the last hour the expiry stops being reference and becomes something to do. It
        // moves out of the VPN submenu to here, where it cannot be missed, because a sign-in takes
        // a browser round trip and being told with five minutes left is being told too late.
        if store.sessionEndingSoon(now: Date()),
           let expiry = MenuPresentation.sessionExpiry(store.vpnStatus?.session, now: Date()) {
            Text(expiry)
        }
        if let error = store.errorMessage {
            Text(error)
        }
    }

    @ViewBuilder
    private var vpnMenu: some View {
        vpnMenuContent
            // Disabled, not hidden. A person who opens this menu looking for the VPN should find it
            // where it always is and see that it is unavailable, rather than watch it vanish and
            // wonder what else the app has lost. The Sign In button above says what to do.
            .disabled(!store.vpnControlsUsable)
    }

    @ViewBuilder
    private var vpnMenuContent: some View {
        Menu("VPN") {
            switch store.vpnMenuMode {
            case .signedOut:
                // A STATE, not a control. The old contents said "Sign Out" for a session that had
                // already ended, over a cluster ticked as connected while nothing routed. Both were
                // claims, and greying them left the claims intact. What is true is this one line;
                // the Sign In button above is the thing to do about it.
                Text("Sign in to use the VPN")
            case .connected:
                vpnClusters
                Divider()
                // When the tunnel ends by itself. Next to the button that ends it deliberately.
                if let expiry = MenuPresentation.sessionExpiry(store.vpnStatus?.session, now: Date()) {
                    Text(expiry)
                }
                /*
                 DISCONNECT, not "Sign Out". This ends the tunnel and leaves the person signed in,
                 which is what `vpn down` has always actually done; calling it Sign Out was the app
                 asserting that a VPN session and an identity were the same thing. Sign Out is now a
                 separate item that ends the identity, and the tunnel with it.
                */
                Button("Disconnect") {
                    coordinator.disconnectVPN()
                }
            case .disconnected:
                /*
                 Connecting can still need a browser round trip: conductor mints a VPN session only
                 from a sign-in in the last five minutes. That is a CONFIRMATION, and the window says
                 so. The person stays signed in throughout and the account cannot change.
                */
                Button("Connect") {
                    coordinator.beginSignIn(purpose: .confirm)
                }
            }
        }
    }

    @ViewBuilder
    private var vpnClusters: some View {
        if let vpn = store.vpnStatus, !vpn.connectableClusters.isEmpty {
            ForEach(vpn.connectableClusters) { cluster in
                let clusterLabel = MenuPresentation.clusterLabel(cluster)
                Toggle(isOn: Binding(
                    get: { cluster.connected },
                    set: { _ in
                        let command = DesktopCommands.toggleCluster(
                            cluster.cid,
                            isConnected: cluster.connected
                        )
                        let message = cluster.connected
                            ? "Disconnecting \(clusterLabel)…"
                            : "Connecting \(clusterLabel)…"
                        coordinator.perform(command, message: message)
                    }
                )) {
                    Text(clusterLabel)
                }
            }
        } else {
            Text("No VPN clusters available")
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        Group {
            /*
             DISABLED, NOT HIDDEN, when there is nothing to install. Same rule as the VPN submenu:
             a person who opens this menu looking for it should find it where it always is.
            */
            Button(store.updateActionTitle) { coordinator.updateRunOS() }
                .disabled(!store.updateActionEnabled)
            /*
             SHOWN ONLY WHILE THERE IS DRIFT, unlike Update RunOS above, which is disabled rather
             than hidden. The difference is that Update is a thing people come looking for and this
             is not: a permanent "Restart VPN" would read as something they ought to be doing.
             Its presence IS the message.
            */
            if store.vpnRestartRequired {
                Button(MenuPresentation.vpnRestartTitle) { coordinator.restartVPNService() }
                    .disabled(store.isBusy)
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            Toggle(AutoConnect.menuLabel, isOn: Binding(
                get: { startupConnect.isEnabled },
                set: { startupConnect.setEnabled($0) }
            ))
            if let error = loginItem.errorMessage {
                Text(error)
            }
            /*
             SIGN OUT LIVES HERE, beside the other things that are about this machine rather than
             about the tunnel, and it is only offered when there is an identity to end.

             It runs `runos logout`, which clears the credential AND drops the tunnel (FPL26 D3).
             The old Sign Out was inside the VPN submenu and ran `vpn down`, which ended the session
             and left the machine signed in.
            */
            if store.signedIn {
                Divider()
                Button("Sign Out") { coordinator.signOut() }
            }
        }
    }

}

@MainActor
struct AboutDetails: Equatable, Sendable {
    let desktopVersion: String
    let cliVersion: String?
    let accountId: String?
    let companyName: String?
    /// A snapshot of the tunnel for the network stats; nil hides the section entirely.
    let vpn: VPNStatus?
    /// The last hour of traffic in five-minute buckets, oldest first, with its total.
    let trafficSlots: [Int64]
    let trafficTotal: Int64
}

enum AboutLayout {
    static let panelWidth: CGFloat = 400
    static let panelHeight: CGFloat = 330
    static let contentWidth: CGFloat = 336
}

@MainActor
struct AboutPresenter {
    private let showPanel: (AboutDetails) -> Void

    init(showPanel: @escaping (AboutDetails) -> Void) {
        self.showPanel = showPanel
    }

    func show(_ details: AboutDetails) {
        showPanel(details)
    }

    static let live = AboutPresenter { details in
        DispatchQueue.main.async {
            AboutWindowController.shared.show(details)
        }
    }
}

@MainActor
private final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSPanel?

    func show(_ details: AboutDetails) {
        let panel = window ?? makePanel()
        window = panel
        let hosting = NSHostingView(rootView: AboutContentView(details: details))
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: AboutLayout.panelWidth, height: AboutLayout.panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About RunOS Desktop"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct AboutContentView: View {
    let details: AboutDetails

    private var connectedClusters: [VPNCluster] {
        details.vpn?.clusters.filter { $0.connected && $0.reachable } ?? []
    }

    var body: some View {
        VStack(spacing: 12) {
            Image("AboutIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)
            Text("RunOS Desktop")
                .font(.title2.bold())
            VStack(spacing: 3) {
                Text("Desktop version \(details.desktopVersion)")
                Text("CLI version \(details.cliVersion ?? "Unavailable")")
                if let accountId = details.accountId {
                    Text("Signed in: \(accountId)")
                }
                if let companyName = details.companyName {
                    Text("Company: \(companyName)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let vpn = details.vpn, vpn.running {
                Divider().frame(width: AboutLayout.contentWidth)
                networkSection(vpn)
            }
            Text("RunOS brings cloud infrastructure to your own hardware.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link("runos.com", destination: URL(string: "https://runos.com")!)
                Link("support@runos.com", destination: URL(string: "mailto:support@runos.com")!)
            }
            Button("Close") {
                AboutWindowController.shared.close()
            }
            .keyboardShortcut(.cancelAction)
        }
        .frame(width: AboutLayout.contentWidth)
        .padding(.vertical, 20)
        .frame(width: AboutLayout.panelWidth)
    }

    @ViewBuilder
    private func networkSection(_ vpn: VPNStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            statRow("Tunnel", [vpn.interface, vpn.address].compactMap { $0 }.joined(separator: "  ·  "))
            trafficChart
            ForEach(connectedClusters) { cluster in
                Divider()
                statRow(MenuPresentation.clusterLabel(name: cluster.name, cid: cluster.cid), cluster.endpoint ?? "unknown")
                statRow(
                    "Traffic",
                    "↓ \(StatsFormatting.bytes(cluster.rxBytes))   ↑ \(StatsFormatting.bytes(cluster.txBytes))"
                )
                statRow("Handshake", StatsFormatting.handshake(cluster.lastHandshake))
                if let resolver = cluster.resolver {
                    statRow("Resolver", resolver)
                }
            }
        }
        .font(.callout)
        .frame(width: AboutLayout.contentWidth, alignment: .leading)
    }

    /*
     The last hour, five minutes per bar, oldest on the left. Bars scale to the busiest bucket;
     an idle hour renders as a flat baseline rather than nothing, so the chart's presence does
     not depend on traffic.
     */
    private var trafficChart: some View {
        let slots = details.trafficSlots
        let peak = max(slots.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, bytes in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(bytes > 0 ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: max(2, CGFloat(bytes) / CGFloat(peak) * 36))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 36, alignment: .bottom)
            HStack {
                Text("Last hour")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(StatsFormatting.bytes(details.trafficTotal))
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

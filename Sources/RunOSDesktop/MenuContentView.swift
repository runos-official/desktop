import AppKit
import SwiftUI

enum MenuPresentation {
    /// The menu item that appears only while the VPN service is on a different build. Named for the
    /// action, because its PRESENCE is what says a restart is needed; the words do not have to
    /// carry that as well.
    static let vpnRestartTitle = "Restart VPN"

    /// Whether the greyed status line at the top of the menu should show the running operation.
    ///
    /// The Sign In and Renew buttons carry the operation text themselves while one runs ("Finishing
    /// sign in…" replaces "Sign In"), so printing it again above the button read as two sign-ins,
    /// or as something stuck (FCR 1726). The line is for an operation no button already says.
    static func showsOperationLine(
        operationMessage: String?, signInButtonShown: Bool, renewButtonShown: Bool, updateButtonShown: Bool = false
    ) -> Bool {
        guard let operationMessage, !operationMessage.isEmpty else { return false }
        // The Update RunOS item reads "Updating RunOS…" while an update runs, so it carries the text too.
        return !signInButtonShown && !renewButtonShown && !updateButtonShown
    }

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

    /// What to say after a renewal, from the session as the CLI now reports it. Nil when there is no
    /// valid session to name the end of, so the notice never claims a renewal it cannot show.
    static func sessionRenewedNotice(_ session: VPNSession?, now: Date, timeZone: TimeZone = .current) -> String? {
        let prefix = "Session expires "
        guard let expiry = sessionExpiry(session, now: now, timeZone: timeZone), expiry.hasPrefix(prefix) else {
            return nil
        }
        return "VPN session renewed. It ends " + expiry.dropFirst(prefix.count) + "."
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

/*
 Draws `MenuModel`. It decides nothing: what is in the menu, in what order, and what is enabled is
 all in the model, where a test can run every state through it.
*/
struct MenuContentView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var startupConnect: StartupConnectController

    private var store: StateStore { coordinator.store }

    private var layout: MenuLayout {
        MenuModel.build(
            store: store,
            launchAtLogin: loginItem.isEnabled,
            connectAutomatically: startupConnect.isEnabled,
            loginItemError: loginItem.errorMessage,
            now: Date())
    }

    var body: some View {
        let current = layout
        MenuItemsView(items: current.items) { perform($0, details: current.details) }
            .onAppear {
                coordinator.setMenuOpen(true)
                // The person can change this in System Settings, so the toggle is re-read rather than
                // remembered from launch. See LoginItemController.refresh.
                loginItem.refresh()
            }
            .onDisappear { coordinator.setMenuOpen(false) }
    }

    private func perform(_ action: MenuAction, details: String?) {
        switch action {
        case .signIn: coordinator.beginSignIn(purpose: .signIn)
        case .renewSession: coordinator.beginSignIn(purpose: .renew)
        // Connecting can still need a browser round trip: conductor mints a VPN session only from a
        // sign-in in the last five minutes. That is a CONFIRMATION, and the window says so.
        case .connect: coordinator.beginSignIn(purpose: .confirm)
        case .disconnect: coordinator.disconnectVPN()
        case .signOut: coordinator.signOut()
        case .installVPNService: coordinator.installVPNService()
        case .restartVPN: coordinator.restartVPNService()
        case .updateRunOS: coordinator.updateRunOS()
        case .toggleCluster(let cid, let connected, let label):
            coordinator.perform(
                DesktopCommands.toggleCluster(cid, isConnected: connected),
                message: connected ? "Disconnecting \(label)…" : "Connecting \(label)…")
        case .switchAccount(let aid):
            if let account = store.accounts.first(where: { $0.aid == aid }) { coordinator.switchAccount(account) }
        case .cancelOperation: coordinator.cancelOperation()
        case .showDetails: ErrorDetailsWindowController.shared.show(details ?? "")
        case .setLaunchAtLogin(let enabled): loginItem.setEnabled(enabled)
        case .setConnectAutomatically(let enabled): startupConnect.setEnabled(enabled)
        case .showConnectionStatus: ConnectionStatusWindowController.shared.show(vpn: store.vpnStatus)
        case .showAbout:
            AboutPresenter.live.show(AboutDetails(
                desktopVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                cliVersion: store.cliVersion,
                accountId: store.activeAccountId,
                companyName: store.cliStatus?.companyName,
                vpn: store.vpnStatus,
                trafficSlots: store.traffic.hourSlots(),
                trafficTotal: store.traffic.lastHourTotal
            ))
        case .quit: NSApplication.shared.terminate(nil)
        }
    }
}

/*
 PLAIN TEXT, no `Label`, in the menu body.

 An icon in a menu item widens the leading column for EVERY item in the group, so one Label pushed
 the sign-in line, the Sign In button and the VPN submenu right, past the checkmark column the rest
 of the menu aligns to. The menu then looked like two menus. The one exception is the active account,
 which carries its checkmark inside its own submenu where nothing else is aligned to it.
*/
private struct MenuItemsView: View {
    let items: [MenuItem]
    let perform: (MenuAction) -> Void

    var body: some View {
        ForEach(items) { item in
            switch item.kind {
            case .divider:
                Divider()
            case .text:
                Text(item.title)
            case .button:
                if item.isOn, item.id.hasPrefix("account.") {
                    Button {
                        if let action = item.action { perform(action) }
                    } label: {
                        Label(item.title, systemImage: "checkmark")
                    }
                    .disabled(!item.enabled)
                } else {
                    Button(item.title) {
                        if let action = item.action { perform(action) }
                    }
                    .disabled(!item.enabled)
                }
            case .toggle:
                Toggle(item.title, isOn: Binding(
                    get: { item.isOn },
                    set: { _ in if let action = item.action { perform(action) } }
                ))
                .disabled(!item.enabled)
            case .submenu(let children):
                Menu(item.title) {
                    MenuItemsView(items: children, perform: perform)
                }
                .disabled(!item.enabled)
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

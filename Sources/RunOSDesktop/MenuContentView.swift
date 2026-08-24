import AppKit
import SwiftUI

enum MenuPresentation {
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
     What a person is told when the CLI and the VPN are on different accounts.

     The old text was "Account mismatch: CLI sjnnz, VPN rjwrn" followed by "Run 'runos vpn up' to
     synchronize the VPN account". It named a state without its consequence and then asked the
     person to go and type a command the app can run itself.

     The consequence is the part that matters: the VPN, and every cluster listed under it, belongs
     to the other account. Until that is said, someone reading this menu is looking at another
     account's clusters and has no way to know.
     */
    static func signInPrompt(account: String?) -> String {
        "Sign in to use the VPN with \(accountName(account))."
    }

    private static func accountName(_ id: String?) -> String {
        let trimmed = (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "another account" : trimmed
    }

    static func clusterLabel(_ cluster: VPNCluster) -> String {
        let base = clusterLabel(name: cluster.name, cid: cluster.cid)
        guard cluster.isDeadConnection else { return base }
        let reason = (cluster.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "\(base) — not connected"
            : "\(base) — not connected: \(reason)"
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
            if store.canCancelOperation {
                Button(store.cancelOperationLabel ?? "Cancel Operation", role: .cancel) {
                    coordinator.cancelOperation()
                }
            }
            Divider()
            Button("About RunOS Desktop") {
                AboutPresenter.live.show(AboutDetails(
                    desktopVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                    cliVersion: store.cliVersion,
                    accountId: store.activeAccountId,
                    companyName: store.cliStatus?.companyName,
                    vpn: store.vpnStatus
                ))
            }
            Button("Quit RunOS Desktop") { NSApplication.shared.terminate(nil) }
        }
        .onAppear { coordinator.setMenuOpen(true) }
        .onDisappear { coordinator.setMenuOpen(false) }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if let operation = store.operationMessage {
            Label(operation, systemImage: "clock")
        }
        if store.vpnSignInRequired {
            // The app has already tried and cannot do this one: Conductor wants a fresh sign-in
            // and an unattended run may not open a browser. So this is the only thing said, and
            // it is a thing to do rather than a state to explain.
            Label(MenuPresentation.signInPrompt(account: store.activeAccountId), systemImage: "person.badge.key")
            Button("Sign In") {
                coordinator.setVPN(enabled: true)
            }
        }
        if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var vpnMenu: some View {
        Menu("VPN") {
            if let vpn = store.vpnStatus, vpn.running {
                if vpn.connectableClusters.isEmpty {
                    Text("No VPN clusters available")
                } else {
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
                }
                let hints = peeringHints(vpn.connectableClusters)
                if !hints.isEmpty {
                    Divider()
                    ForEach(hints, id: \.self) { hint in
                        Text(hint)
                    }
                }
                Divider()
                // The one action that ends the 24-hour session; the next connect opens the
                // browser sign-in again. Cluster toggles above never do this.
                Button("Sign Out") {
                    coordinator.setVPN(enabled: false)
                }
            } else {
                Button("Connect") {
                    coordinator.setVPN(enabled: true)
                }
            }
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        Group {
            Button(store.updateActionTitle) { coordinator.updateRunOS() }
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            Toggle("Connect VPN at Startup", isOn: Binding(
                get: { startupConnect.isEnabled },
                set: { startupConnect.setEnabled($0) }
            ))
            if let error = loginItem.errorMessage {
                Text(error)
            }
        }
    }

    private func peeringHints(_ clusters: [VPNCluster]) -> [String] {
        let connected = Set(clusters.filter(\.connected).map(\.cid))
        let available = Set(clusters.map(\.cid))
        return clusters.filter(\.connected).flatMap { cluster in
            cluster.peeredWith.filter { available.contains($0) && !connected.contains($0) }.map { peer in
                "\(peer) is peered with \(cluster.cid). Connect \(peer) for private routes and DNS."
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
            statRow("DNS", dnsSummary(vpn))
            ForEach(connectedClusters) { cluster in
                Divider()
                statRow(MenuPresentation.clusterLabel(name: cluster.name, cid: cluster.cid), cluster.endpoint ?? "—")
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

    private func dnsSummary(_ vpn: VPNStatus) -> String {
        guard let dns = vpn.dns else { return "—" }
        if dns.available {
            return "private zones active" + (dns.mode.map { " (\($0))" } ?? "")
        }
        let error = (dns.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? "unavailable" : "unavailable: \(error)"
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

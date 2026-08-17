import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var loginItem: LoginItemController
    @State private var showsAbout = false

    private var store: StateStore { coordinator.store }

    var body: some View {
        Group {
            accountSection
            vpnSection
            clusterSection
            accountPicker
            actionSection
            Divider()
            Button("About RunOS Desktop") { showsAbout = true }
            Button("Quit RunOS Desktop") { NSApplication.shared.terminate(nil) }
        }
        .disabled(store.isBusy)
        .onAppear { coordinator.setMenuOpen(true) }
        .onDisappear { coordinator.setMenuOpen(false) }
        .alert("RunOS Desktop", isPresented: $showsAbout) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("RunOS Desktop is an unsigned menu-bar facade for the RunOS CLI.\n\nElastic License 2.0")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("CLI Account") {
            Text(store.activeAccountId ?? "Not signed in")
            if store.cliStatus?.vpnAccountMismatch == true {
                Label("VPN account: \(store.cliStatus?.vpnAccountId ?? "unknown")", systemImage: "exclamationmark.triangle")
                Text("Run 'runos vpn up' to synchronize the VPN account.")
            }
        }
        if let operation = store.operationMessage {
            Label(operation, systemImage: "clock")
        }
        if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var vpnSection: some View {
        Section("VPN") {
            Toggle("Connected", isOn: Binding(
                get: { store.vpnStatus?.running == true },
                set: { enabled in
                    coordinator.perform(DesktopCommands.setVPN(enabled: enabled), message: enabled ? "Connecting VPN…" : "Disconnecting VPN…")
                }
            ))
            if store.vpnStatus?.session.loginRequired == true {
                Text("Browser authentication is required.")
            }
        }
    }

    @ViewBuilder
    private var clusterSection: some View {
        if let vpn = store.vpnStatus, !vpn.clusters.isEmpty {
            Section("Clusters") {
                ForEach(vpn.clusters) { cluster in
                    Button {
                        coordinator.perform(
                            DesktopCommands.setCluster(cluster.cid, connected: cluster.connected),
                            message: "Updating \(cluster.name)…"
                        )
                    } label: {
                        Label(cluster.name.isEmpty ? cluster.cid : cluster.name, systemImage: cluster.connected ? "checkmark.circle.fill" : "circle")
                    }
                    if !cluster.reachable, let reason = cluster.reason, !reason.isEmpty {
                        Text("\(cluster.cid): \(reason)")
                    }
                }
                ForEach(peeringHints(vpn.clusters), id: \.self) { hint in
                    Text(hint)
                }
            }
        }
    }

    @ViewBuilder
    private var accountPicker: some View {
        Section("Accounts") {
            ForEach(store.accounts) { account in
                Button {
                    coordinator.perform(DesktopCommands.switchAccount(account.accountId), message: "Authenticating \(account.accountId)…")
                } label: {
                    Label(account.accountId, systemImage: account.active ? "checkmark" : "person.crop.circle")
                }
            }
            Button("Add Account…") {
                coordinator.perform(["account", "add", "--json"], message: "Waiting for browser authentication…")
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            Button("Update RunOS") { coordinator.updateRunOS() }
            Toggle("Launch at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            if let error = loginItem.errorMessage {
                Text(error)
            }
        }
    }

    private func peeringHints(_ clusters: [VPNCluster]) -> [String] {
        let connected = Set(clusters.filter(\.connected).map(\.cid))
        return clusters.filter(\.connected).flatMap { cluster in
            cluster.peeredWith.filter { !connected.contains($0) }.map { peer in
                "\(peer) is peered with \(cluster.cid). Connect \(peer) for private routes and DNS."
            }
        }
    }
}

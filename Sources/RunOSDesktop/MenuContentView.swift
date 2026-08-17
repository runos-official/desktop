import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var loginItem: LoginItemController

    private var store: StateStore { coordinator.store }

    var body: some View {
        Group {
            accountSection
            vpnSection
            clusterSection
            accountPicker
            actionSection
            Divider()
            Button("About RunOS Desktop") { AboutPresenter.live.show() }
            Button("Quit RunOS Desktop") { NSApplication.shared.terminate(nil) }
        }
        .disabled(store.isBusy)
        .onAppear { coordinator.setMenuOpen(true) }
        .onDisappear { coordinator.setMenuOpen(false) }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("CLI Account") {
            Text(store.activeAccountId ?? "Not signed in")
            if store.cliDevelopment, let version = store.cliVersion {
                Text("Development CLI: \(version)")
            }
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

@MainActor
struct AboutPresenter {
    private let showPanel: () -> Void

    init(showPanel: @escaping () -> Void) {
        self.showPanel = showPanel
    }

    func show() {
        showPanel()
    }

    static let live = AboutPresenter {
        DispatchQueue.main.async {
            AboutWindowController.shared.show()
        }
    }
}

@MainActor
private final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSPanel?

    func show() {
        let panel = window ?? makePanel()
        window = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About RunOS Desktop"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: AboutContentView())
        return panel
    }
}

private struct AboutContentView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image("AboutIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 50, height: 50)
            Text("RunOS Desktop")
                .font(.title2.bold())
            Text("Version \(version)")
            Text("RunOS brings cloud infrastructure to your own hardware.")
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
        .frame(width: 360, height: 260)
    }
}

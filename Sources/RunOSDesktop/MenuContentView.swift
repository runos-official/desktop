import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var loginItem: LoginItemController

    private var store: StateStore { coordinator.store }

    var body: some View {
        Group {
            Group {
                statusMessages
                vpnControl
                connectMenu
                accountMenu
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
            Button("About RunOS Desktop") { AboutPresenter.live.show() }
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
        if store.cliStatus?.vpnAccountMismatch == true {
            Label(
                "Account mismatch: CLI \(store.activeAccountId ?? "unknown"), VPN \(store.cliStatus?.vpnAccountId ?? "unknown")",
                systemImage: "exclamationmark.triangle"
            )
            Text("Run 'runos vpn up' to synchronize the VPN account.")
        }
        if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private var vpnControl: some View {
        Group {
            Button(store.vpnStatus?.running == true ? "Disconnect VPN" : "Connect VPN") {
                coordinator.setVPN(enabled: store.vpnStatus?.running != true)
            }
            if store.vpnStatus?.session.loginRequired == true {
                Text("Browser authentication is required.")
            }
        }
    }

    @ViewBuilder
    private var connectMenu: some View {
        Menu("Connect") {
            if let vpn = store.vpnStatus {
                if vpn.connectableClusters.isEmpty {
                    Text("No VPN clusters available")
                } else {
                    ForEach(vpn.connectableClusters) { cluster in
                        Toggle(isOn: Binding(
                            get: { cluster.connected },
                            set: { _ in
                                coordinator.perform(
                                    DesktopCommands.setCluster(cluster.cid, connected: cluster.connected),
                                    message: cluster.connected
                                        ? "Disconnecting \(cluster.name)…"
                                        : "Connecting \(cluster.name)…"
                                )
                            }
                        )) {
                            Text(cluster.name.isEmpty ? cluster.cid : cluster.name)
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
            } else {
                Text("VPN status is unavailable")
            }
        }
    }

    @ViewBuilder
    private var accountMenu: some View {
        Menu("Account") {
            ForEach(store.accounts) { account in
                Button {
                    coordinator.perform(
                        DesktopCommands.switchAccount(account.accountId),
                        message: "Authenticating \(account.accountId)…",
                        cancellable: true
                    )
                } label: {
                    Label(account.accountId, systemImage: account.active ? "checkmark" : "person.crop.circle")
                }
            }
            if !store.accounts.isEmpty {
                Divider()
            }
            Button("Add Account…") {
                coordinator.perform(
                    ["account", "add", "--json"],
                    message: "Waiting for browser authentication…",
                    cancellable: true
                )
            }
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        Group {
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
        let available = Set(clusters.map(\.cid))
        return clusters.filter(\.connected).flatMap { cluster in
            cluster.peeredWith.filter { available.contains($0) && !connected.contains($0) }.map { peer in
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

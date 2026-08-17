import AppKit
import SwiftUI

enum MenuPresentation {
    static func clusterLabel(name: String, cid: String) -> String {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? cid : "\(displayName) (\(cid))"
    }
}

struct MenuContentView: View {
    @ObservedObject var coordinator: RefreshCoordinator
    @ObservedObject var loginItem: LoginItemController

    private var store: StateStore { coordinator.store }

    var body: some View {
        Group {
            Group {
                statusMessages
                vpnMenu
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
            Button("About RunOS Desktop") {
                AboutPresenter.live.show(AboutDetails(
                    desktopVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                    cliVersion: store.cliVersion,
                    accountId: store.activeAccountId,
                    companyName: store.cliStatus?.companyName
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
    private var vpnMenu: some View {
        Menu("VPN") {
            if let vpn = store.vpnStatus, vpn.running {
                if vpn.connectableClusters.isEmpty {
                    Text("No VPN clusters available")
                } else {
                    let connectedClusterCount = vpn.connectableClusters.filter(\.connected).count
                    ForEach(vpn.connectableClusters) { cluster in
                        let clusterLabel = MenuPresentation.clusterLabel(name: cluster.name, cid: cluster.cid)
                        Toggle(isOn: Binding(
                            get: { cluster.connected },
                            set: { _ in
                                let command = DesktopCommands.toggleCluster(
                                    cluster.cid,
                                    isConnected: cluster.connected,
                                    connectedClusterCount: connectedClusterCount
                                )
                                let disconnectsVPN = command == DesktopCommands.setVPN(enabled: false)
                                let message: String
                                if disconnectsVPN {
                                    message = "Disconnecting VPN…"
                                } else if cluster.connected {
                                    message = "Disconnecting \(clusterLabel)…"
                                } else {
                                    message = "Connecting \(clusterLabel)…"
                                }
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
                Button("Disconnect") {
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
            Button(store.updateActionTitle) { coordinator.updateRunOS() }
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
struct AboutDetails: Equatable, Sendable {
    let desktopVersion: String
    let cliVersion: String?
    let accountId: String?
    let companyName: String?
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
        panel.contentView = NSHostingView(rootView: AboutContentView(details: details))
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
        .frame(width: AboutLayout.panelWidth, height: AboutLayout.panelHeight)
    }
}

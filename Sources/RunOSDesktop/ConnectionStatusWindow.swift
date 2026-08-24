import AppKit
import SwiftUI

/*
 The Connection Status window: for every connected cluster, ping its VPN server, ping each of
 its nodes over the overlay, and resolve a name in its private zone, one step at a time so the
 person watches it happen. Everything runs sequentially on purpose: the point is to see WHERE
 the path breaks, not to finish fast.
 */

enum DiagnosticState: Equatable {
    case pending
    case running
    case passed(String)
    case failed(String)
}

struct DiagnosticStep: Identifiable, Equatable {
    let id: String
    let cluster: String
    let title: String
    var state: DiagnosticState = .pending
}

@MainActor
final class ConnectionStatusRunner: ObservableObject {
    @Published private(set) var steps: [DiagnosticStep] = []
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?

    func start(vpn: VPNStatus?) {
        task?.cancel()
        steps = []
        guard let vpn, vpn.running else {
            steps = [DiagnosticStep(id: "off", cluster: "", title: "VPN is not connected", state: .failed("Connect the VPN first"))]
            return
        }
        let clusters = vpn.clusters.filter { $0.connected && $0.reachable }
        guard !clusters.isEmpty else {
            steps = [DiagnosticStep(id: "none", cluster: "", title: "No connected clusters", state: .failed("Connect a cluster first"))]
            return
        }
        isRunning = true
        task = Task { [weak self] in
            for cluster in clusters {
                await self?.testCluster(cluster)
            }
            self?.isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        isRunning = false
    }

    private func testCluster(_ cluster: VPNCluster) async {
        let label = MenuPresentation.clusterLabel(name: cluster.name, cid: cluster.cid)

        // 1. The VPN server itself, at its overlay address.
        if let resolver = cluster.resolver {
            await runStep(id: "\(cluster.cid)-server", cluster: label, title: "Ping VPN server (\(resolver))") {
                await Self.ping(resolver)
            }
        }

        // 2. Every node of the cluster, discovered live from the CLI.
        var nodes: [DiagnosticsNode] = []
        await runStep(id: "\(cluster.cid)-nodes", cluster: label, title: "List nodes") {
            do {
                let result = try await Self.run("/usr/bin/env", ["runos", "nodes", "list", "--cid", cluster.cid, "-j"], viaCli: true)
                let list = try JSONDecoder.runOS.decode(DiagnosticsNodeList.self, from: result.stdout)
                nodes = list.nodes
                return .passed("\(list.nodes.count) node(s)")
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        for node in nodes {
            guard let address = node.vpnIp, !address.isEmpty else { continue }
            await runStep(id: "\(cluster.cid)-node-\(address)", cluster: label, title: "Ping \(node.label) (\(address))") {
                await Self.ping(address)
            }
        }

        // 3. A name in the cluster's private zone, through the split-DNS path a browser or
        //    kubectl would take (dscacheutil consults /etc/resolver; dig would bypass it).
        if let zone = cluster.zones?.first {
            let name = "k8s.\(zone)"
            await runStep(id: "\(cluster.cid)-dns", cluster: label, title: "Resolve \(name)") {
                do {
                    let result = try await Self.run("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", name])
                    let addresses = ConnectionDiagnostics.resolvedAddresses(String(decoding: result.stdout, as: UTF8.self))
                    guard let first = addresses.first else {
                        return .failed("did not resolve")
                    }
                    return ConnectionDiagnostics.isPrivateIPv4(first)
                        ? .passed(first)
                        : .failed("resolved publicly (\(first)), not over the VPN")
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        }
    }

    private func runStep(
        id: String,
        cluster: String,
        title: String,
        _ body: () async -> DiagnosticState
    ) async {
        guard !Task.isCancelled else { return }
        steps.append(DiagnosticStep(id: id, cluster: cluster, title: title, state: .running))
        let state = await body()
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].state = state
        }
    }

    private static func ping(_ address: String) async -> DiagnosticState {
        do {
            let result = try await run("/sbin/ping", ["-c", "2", "-W", "2000", address])
            let verdict = ConnectionDiagnostics.pingVerdict(
                exitCode: result.exitCode,
                output: String(decoding: result.stdout, as: UTF8.self)
            )
            return verdict.reachable ? .passed(verdict.detail) : .failed(verdict.detail)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func run(_ path: String, _ arguments: [String], viaCli: Bool = false) async throws -> CLIResult {
        if viaCli {
            let runner = try CLIRunner(executableURL: CLIPathResolver.resolve())
            // Drop the leading "runos": the runner IS the CLI.
            return try await runner.run(Array(arguments.dropFirst()))
        }
        let runner = try CLIRunner(executableURL: URL(filePath: path))
        return try await runner.run(arguments)
    }
}

@MainActor
final class ConnectionStatusWindowController {
    static let shared = ConnectionStatusWindowController()
    private var window: NSPanel?
    private let runner = ConnectionStatusRunner()

    func show(vpn: VPNStatus?) {
        let panel = window ?? makePanel()
        window = panel
        panel.contentView = NSHostingView(
            rootView: ConnectionStatusView(runner: runner) { [weak self] in
                self?.window?.close()
            }
        )
        runner.start(vpn: vpn)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Connection Status"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject var runner: ConnectionStatusRunner
    let onClose: () -> Void

    private var clusters: [String] {
        var seen: [String] = []
        for step in runner.steps where !seen.contains(step.cluster) {
            seen.append(step.cluster)
        }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(clusters, id: \.self) { cluster in
                        if !cluster.isEmpty {
                            Text(cluster)
                                .font(.headline)
                                .padding(.top, 8)
                        }
                        ForEach(runner.steps.filter { $0.cluster == cluster }) { step in
                            stepRow(step)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack {
                Button("Run Again") {
                    // A rerun reads the tunnel as it is NOW, not as it was when the window opened.
                    ConnectionStatusWindowController.shared.show(vpn: nil)
                }
                .hidden()
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 420, height: 440)
    }

    @ViewBuilder
    private func stepRow(_ step: DiagnosticStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stateIcon(step.state)
                .frame(width: 16)
            Text(step.title)
            Spacer(minLength: 12)
            Text(stateDetail(step.state))
                .foregroundStyle(stateColor(step.state))
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func stateIcon(_ state: DiagnosticState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func stateDetail(_ state: DiagnosticState) -> String {
        switch state {
        case .pending: ""
        case .running: "…"
        case .passed(let detail): detail
        case .failed(let detail): detail
        }
    }

    private func stateColor(_ state: DiagnosticState) -> Color {
        switch state {
        case .failed: .red
        default: .secondary
        }
    }
}

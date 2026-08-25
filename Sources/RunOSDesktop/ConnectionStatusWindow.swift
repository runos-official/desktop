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

    /*
     The cluster sections, in the order they are shown.

     PUBLISHED SEPARATELY rather than derived from `steps`, because the clusters are now tested
     CONCURRENTLY. Deriving section order from first appearance made it a race: whichever cluster's
     first ping returned first went to the top, so the same window could order itself differently on
     two consecutive runs. The order is a property of the cluster list, which is known before any
     packet is sent, so it is settled there.
    */
    @Published private(set) var clusterOrder: [String] = []

    private var task: Task<Void, Never>?

    func start(vpn: VPNStatus?) {
        task?.cancel()
        steps = []
        clusterOrder = []
        guard let vpn, vpn.running else {
            steps = [DiagnosticStep(id: "off", cluster: "", title: "VPN is not connected", state: .failed("Connect the VPN first"))]
            return
        }
        // Before any packet: an expired session drops everything over the overlay while the tunnel
        // interface stays up and the clusters still read connected. Running a dozen pings that
        // CANNOT pass, and leaving the person to infer why from a column of red, is the long way
        // round to a fact the CLI already reported.
        if let reason = ConnectionDiagnostics.sessionBlock(vpn.session) {
            steps = [DiagnosticStep(id: "session", cluster: "", title: "VPN session", state: .failed(reason))]
            return
        }
        let clusters = vpn.clusters.filter { $0.connected && $0.reachable }
        guard !clusters.isEmpty else {
            steps = [DiagnosticStep(id: "none", cluster: "", title: "No connected clusters", state: .failed("Connect a cluster first"))]
            return
        }
        isRunning = true
        clusterOrder = clusters.map { MenuPresentation.clusterLabel(name: $0.name, cid: $0.cid) }
        /*
         EVERY CLUSTER AT ONCE. Sequentially, the window took the SUM of every cluster's checks, and
         each cluster is a handful of pings with their own timeouts: an unreachable one made every
         cluster after it wait out its failure before starting. A person looking at the window is
         asking "which of these is broken", and the slow answer is the one they most need.

         Concurrency is safe without a lock because this type is @MainActor: the child tasks
         interleave at their await points, and every mutation of `steps` runs on the main actor.
         Ordering within a cluster is unaffected, since each cluster's own steps still run in
         sequence inside its task.
        */
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for cluster in clusters {
                    group.addTask { await self?.testCluster(cluster) }
                }
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
                return .failed(ConnectionDiagnostics.concise(error.localizedDescription))
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
                    return .failed(ConnectionDiagnostics.concise(error.localizedDescription))
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
            // PROBE, not run. A host that does not answer exits 2, and that is the answer this
            // window asked for, not an error: `run` would throw it with the whole of ping's stdout
            // as the message, which is how four lines of raw output ended up in one row.
            let runner = try CLIRunner(executableURL: URL(filePath: "/sbin/ping"))
            let result = try await runner.probe(["-c", "2", "-W", "2000", address])
            let verdict = ConnectionDiagnostics.pingVerdict(
                exitCode: result.exitCode,
                output: String(decoding: result.stdout, as: UTF8.self)
            )
            return verdict.reachable ? .passed(verdict.detail) : .failed(verdict.detail)
        } catch {
            return .failed(ConnectionDiagnostics.concise(error.localizedDescription))
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

    /*
     The settled order from the runner, plus any section the runner did not name.

     The unnamed ones are the single-row outcomes ("VPN is not connected", "VPN session", "No
     connected clusters"), which carry an empty cluster and are not in clusterOrder.
    */
    private var clusters: [String] {
        var seen = runner.clusterOrder
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

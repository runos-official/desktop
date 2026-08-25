import AppKit
import SwiftUI

/*
 The sign-in window.

 Clicking Sign In used to run the CLI, capture its output to a file, and show a spinner until it
 finished. Everything a person needs to complete a browser sign-in SAFELY was in that captured
 output and never reached them:

 - The DEVICE ID. The browser page shows a code, and it only means anything if it matches the one
   the CLI generated. Without seeing the CLI's code there is nothing to compare against, so a page
   that is not the one the CLI opened cannot be told from one that is. The CLI has printed
   "verify this matches the browser" to a terminal for as long as this flow has existed.
 - The URL. When the browser does not open, and on a locked-down machine it often does not, this is
   the only way in. It was written to stdout and thrown away.

 So the window shows both, keeps saying whether the browser has authorised yet, and can be
 cancelled. Cancelling terminates the CLI process, which is the only way to stop a poll loop that
 is waiting on a person.
*/

enum SignInPhase: Equatable {
    case starting
    case waiting
    case authorized
    case failed(String)
}

@MainActor
final class SignInRunner: ObservableObject {
    @Published private(set) var deviceID: String?
    @Published private(set) var url: String?
    @Published private(set) var browserOpened = false
    @Published private(set) var phase: SignInPhase = .starting
    @Published private(set) var copied = false

    private var task: Task<Void, Never>?
    private let runner: CLIRunner?
    private let onFinished: () -> Void

    /*
     Where a streamed line lands.

     `CLIRunner.stream` takes a @Sendable handler, which cannot capture this model: it runs on
     whatever thread the pipe delivers on. The handler hops to the main actor and posts here, and
     only one sign-in window exists at a time, so a single current model is the whole of the routing
     this needs.
    */
    @MainActor private static weak var current: SignInRunner?

    @MainActor static func deliver(_ event: SignInEvent) {
        current?.apply(event)
    }

    init(runner: CLIRunner?, onFinished: @escaping () -> Void) {
        self.runner = runner
        self.onFinished = onFinished
    }

    func start() {
        guard let runner else {
            phase = .failed("The RunOS CLI is not available.")
            return
        }
        task?.cancel()
        deviceID = nil
        url = nil
        phase = .starting
        SignInRunner.current = self
        task = Task { [weak self] in
            do {
                // `vpn up --json` signs in AND connects, which is what the Sign In button has always
                // done. The sign-in half reports as events; the rest is the CLI's own business.
                //
                // The handler runs off the main actor, on whatever thread the pipe delivers on, so
                // each line is hopped back before it touches published state.
                let code = try await runner.stream(DesktopCommands.setVPN(enabled: true) + ["--json"]) { line in
                    guard let event = SignInEvent.parse(line) else { return }
                    Task { @MainActor in SignInRunner.deliver(event) }
                }
                await self?.finish(exitCode: code)
            } catch is CancellationError {
            } catch {
                await self?.fail(ConnectionDiagnostics.concise(error.localizedDescription))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .failed("Sign in cancelled.")
    }

    func copyURL() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
    }

    func openURL() {
        guard let url, let parsed = URL(string: url) else { return }
        NSWorkspace.shared.open(parsed)
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }

    fileprivate func apply(_ event: SignInEvent) {
        switch event {
        case .deviceCode(let id, let link, let opened):
            deviceID = id
            url = link
            browserOpened = opened
            phase = .waiting
        case .pending:
            if phase == .starting { phase = .waiting }
        case .authorized:
            phase = .authorized
        case .failed(_, let message):
            phase = .failed(message)
        }
    }

    /*
     What a finished process means.

     An exit code of 0 is the answer, not the `authorized` event: that event fires when the BROWSER
     authorised, and the CLI still has a token to exchange and a tunnel to bring up after it. Closing
     on the event would report success before the thing had happened.
    */
    private func finish(exitCode: Int32) {
        if exitCode == 0 {
            phase = .authorized
            onFinished()
            return
        }
        if case .failed = phase { return }
        phase = .failed("Sign in did not complete.")
    }
}

@MainActor
final class SignInWindowController {
    static let shared = SignInWindowController()
    private var window: NSPanel?

    func show(runner: CLIRunner?, onFinished: @escaping () -> Void) {
        let panel = window ?? makePanel()
        window = panel
        let model = SignInRunner(runner: runner) { [weak self] in
            onFinished()
            self?.window?.close()
        }
        panel.contentView = NSHostingView(
            rootView: SignInView(model: model) { [weak self] in
                model.cancel()
                self?.window?.close()
            }
        )
        model.start()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sign in to RunOS"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

private struct SignInView: View {
    @ObservedObject var model: SignInRunner
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            deviceCodeSection
            Divider()
            urlSection
            Divider()
            statusSection
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 340)
    }

    @ViewBuilder
    private var deviceCodeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device code")
                .font(.headline)
            if let deviceID = model.deviceID {
                Text(deviceID)
                    .font(.system(.title2, design: .monospaced))
                    .textSelection(.enabled)
                // The instruction is the point. A code nobody is told to compare is decoration, and
                // comparing it is the only thing standing between this flow and an authorised page
                // the CLI never opened.
                Text("Check this matches the code shown in your browser before you approve it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Requesting a code…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.browserOpened ? "Opened in your browser" : "Open this in your browser")
                .font(.headline)
            if let url = model.url {
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(model.copied ? "Copied" : "Copy Link") { model.copyURL() }
                    Button("Open Browser") { model.openURL() }
                }
            } else {
                Text("Waiting for the sign-in link…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .starting, .waiting:
                ProgressView().controlSize(.small)
                Text(model.deviceID == nil ? "Starting…" : "Waiting for you to approve it in the browser…")
            case .authorized:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Approved. Finishing sign in…")
            case .failed(let message):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

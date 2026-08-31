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

/*
 WHAT THIS WINDOW IS DOING, which is two different things that must never be called the same one.

 `signIn` establishes an identity. `confirm` proves the person is still there, because conductor
 mints a VPN session only from a sign-in in the last five minutes; the account cannot change and
 nobody is being signed into anything.

 Wording them the same is what produced "sign in twice": a person who had signed in a minute ago
 was shown a Sign In window when they asked to connect, so it read as the first one having failed.
*/
enum SignInPurpose: Equatable {
    case signIn
    case confirm

    var windowTitle: String {
        switch self {
        case .signIn: return "Sign in to RunOS"
        case .confirm: return "Confirm it's you"
        }
    }

    /// The one line under the title saying why a browser is involved at all.
    var explanation: String {
        switch self {
        case .signIn:
            return "Approve this device in your browser to sign in."
        case .confirm:
            return "You are still signed in. Connecting the VPN needs a recent browser check."
        }
    }

    var arguments: [String] {
        switch self {
        case .signIn: return DesktopCommands.signIn()
        case .confirm: return DesktopCommands.setVPN(enabled: true)
        }
    }

    /*
     WHETHER THE WINDOW OPENS ON SPEC, OR WAITS UNTIL THERE IS SOMETHING TO SHOW.

     MEASURED 2026-08-31 by clicking Connect in the running app, thirty seconds after signing in.
     Conductor was satisfied, so no device code was ever issued, and yet a modal titled "Confirm
     it's you" appeared and vanished on its own. A window that asks you to prove who you are and
     then withdraws the question reads as something having gone wrong, and it is the COMMON case:
     most connects happen while the sign-in is still fresh.

     Sign In is the opposite. The person asked for it, a device code is certain, and opening at once
     is what puts the code on screen before a browser can take focus.
    */
    var presentsWindowImmediately: Bool {
        switch self {
        case .signIn: return true
        case .confirm: return false
        }
    }

    /// What the MENU says while this runs without a window of its own. A silent connect with no
    /// progress anywhere looks like a dead click.
    var busyMessage: String {
        switch self {
        case .signIn: return "Signing in…"
        case .confirm: return "Connecting VPN…"
        }
    }

    /// What to say when the CLI failed and said nothing on stderr for us to quote.
    var genericFailure: String {
        switch self {
        case .signIn: return "Sign in did not complete."
        case .confirm: return "Could not connect the VPN."
        }
    }
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
    let purpose: SignInPurpose

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

    /// Fires once, when a device code first arrives. The controller uses it to bring a deferred
    /// window on screen; a purpose that opens immediately never needs it.
    var onDeviceCode: (() -> Void)?

    /// Fires once when the run finishes, however it finishes. The caller clears its own progress
    /// state on this, which matters most for a run that never opened a window to close.
    var onEnded: (() -> Void)?

    init(runner: CLIRunner?, purpose: SignInPurpose, onFinished: @escaping () -> Void) {
        self.runner = runner
        self.purpose = purpose
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
        let purpose = self.purpose
        task = Task { [weak self] in
            do {
                /*
                 The command is the PURPOSE's, not this window's. `signIn` runs `runos login`, which
                 is the only command in the app that establishes an identity; `confirm` runs
                 `vpn up`, which consumes one and never creates one.

                 The handler runs off the main actor, on whatever thread the pipe delivers on, so
                 each line is hopped back before it touches published state.
                */
                let result = try await runner.stream(purpose.arguments) { line in
                    guard let event = SignInEvent.parse(line) else { return }
                    Task { @MainActor in SignInRunner.deliver(event) }
                }
                await self?.finish(result)
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
        endOnce()
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
        // Recorded so the window stops telling someone to do a thing they have just done.
        browserOpened = true
    }

    private func fail(_ message: String) {
        phase = .failed(message)
        endOnce()
    }

    private func endOnce() {
        onEnded?()
        onEnded = nil
    }

    fileprivate func apply(_ event: SignInEvent) {
        switch event {
        case .deviceCode(let id, let link):
            deviceID = id
            url = link
            phase = .waiting
            // There is now something worth a window. For `.confirm` this is the ONLY thing that
            // opens one, so a connect that needed no confirmation never shows a thing.
            onDeviceCode?()
            onDeviceCode = nil
        case .browserOpened(let opened):
            browserOpened = opened
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
    private func finish(_ result: CLIStreamResult) {
        if result.exitCode == 0 {
            phase = .authorized
            endOnce()
            onFinished()
            return
        }
        endOnce()
        if case .failed = phase { return }
        /*
         THE CLI'S OWN SENTENCE, when it wrote one.

         stderr used to go to `nullDevice`, so every failure after the browser authorised, the token
         exchange, the enrolment, the session mint, arrived here as one generic line. A person was
         told the sign-in "did not complete" and never which part, or what to do. The CLI writes a
         remedy on that stream; showing it costs nothing and is almost always the whole answer.
        */
        phase = .failed(result.failureSentence ?? purpose.genericFailure)
    }
}

@MainActor
final class SignInWindowController {
    static let shared = SignInWindowController()
    private var window: NSPanel?

    /*
     Run the device-code flow, and put a window on screen when the purpose says to.

     `onEnded` fires however it finishes, so the caller can clear whatever it is showing in the menu
     for a run that never opened a window at all.
    */
    func show(
        runner: CLIRunner?,
        purpose: SignInPurpose,
        onFinished: @escaping () -> Void,
        onEnded: @escaping () -> Void = {}
    ) {
        let panel = window ?? makePanel()
        window = panel
        // The title is the purpose's. A window headed "Sign in to RunOS" in front of somebody who
        // signed in a minute ago is what made a routine freshness check read as a failed sign-in.
        panel.title = purpose.windowTitle
        let model = SignInRunner(runner: runner, purpose: purpose) { [weak self] in
            onFinished()
            self?.window?.close()
        }
        panel.contentView = NSHostingView(
            rootView: SignInView(model: model) { [weak self] in
                model.cancel()
                self?.window?.close()
                onEnded()
            }
        )
        model.onEnded = onEnded

        /*
         DEFERRED FOR A CONFIRMATION, IMMEDIATE FOR A SIGN-IN.

         A connect usually needs no confirmation at all, and opening the window on spec meant a
         modal reading "Confirm it's you" appeared and withdrew itself on the common path (measured
         2026-08-31 in the running app). It now waits for a device code, which is the first moment
         there is anything to show or anything to compare.
        */
        if purpose.presentsWindowImmediately {
            presentPanel(panel)
        } else {
            model.onDeviceCode = { [weak self] in
                guard let self, let panel = self.window else { return }
                self.presentPanel(panel)
            }
        }
        model.start()
    }

    private func presentPanel(_ panel: NSPanel) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
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
            Text(model.purpose.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 460, height: 380)
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

    /*
     Opening the browser is a DECISION, not something that happens to you.

     The CLI is run with --no-browser so nothing opens until this button is pressed. That ordering
     is the whole value of the device code: read it here, then go and check it matches there. A
     browser that appears on its own two seconds in puts the code behind a window before anyone has
     read it, and the comparison silently stops happening.
    */
    @ViewBuilder
    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.browserOpened ? "Opened in your browser" : "When you have checked the code")
                .font(.headline)
            if let url = model.url {
                HStack {
                    Button(model.browserOpened ? "Open Browser Again" : "Open Browser") {
                        model.openURL()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button(model.copied ? "Copied" : "Copy Link") { model.copyURL() }
                }
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Waiting for the sign-in link…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        if model.deviceID == nil { return "Starting…" }
        // Before the browser is open there is nothing to approve yet, and saying "waiting for you
        // to approve it in the browser" would be pointing at a window that does not exist.
        return model.browserOpened
            ? "Waiting for you to approve it in the browser…"
            : "Check the code, then open the browser."
    }

    @ViewBuilder
    private var statusSection: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .starting, .waiting:
                ProgressView().controlSize(.small)
                Text(statusLine)
            case .authorized:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model.purpose == .confirm ? "Approved. Connecting…" : "Approved. Finishing sign in…")
            case .failed(let message):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(message).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

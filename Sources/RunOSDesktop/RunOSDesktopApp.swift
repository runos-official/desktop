import SwiftUI
import ServiceManagement

@main
@MainActor
struct RunOSDesktopApp: App {
    @StateObject private var coordinator: RefreshCoordinator
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var startupConnect = StartupConnectController()

    init() {
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(EXIT_SUCCESS)
        }
        let store = StateStore()
        let runner: CLIRunner?
        do {
            runner = try CLIRunner(executableURL: CLIPathResolver.resolve())
        } catch {
            runner = nil
            store.cliAvailable = false
            store.errorMessage = error.localizedDescription
        }
        let coordinator = RefreshCoordinator(store: store, runner: runner)
        _coordinator = StateObject(wrappedValue: coordinator)
        coordinator.start()
        // Connect-at-startup, if the person asked for it. Read straight from the store rather than
        // through the StateObject: property wrappers are not available until the body runs, and
        // this is the one moment the preference exists for.
        if StartupConnectController().isEnabled {
            coordinator.connectVPNAtStartup()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, loginItem: loginItem, startupConnect: startupConnect)
        } label: {
            MenuBarGlyphView(
                state: coordinator.store.menuBarState,
                isActive: coordinator.store.isBusy
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

enum MenuBarIconAnimation {
    static let frameNames = ["MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3"]

    static func imageName(state: MenuBarState, isActive: Bool, reduceMotion: Bool, frame: Int) -> String {
        guard !isActive else {
            return reduceMotion ? "MenuBarIcon" : frameNames[frame % frameNames.count]
        }
        /*
         THE LIT ICON MEANS ONE THING: the VPN is carrying something.

         It used to grey out for `.off` alone, so `.attention` reused the lit icon and was
         indistinguishable from `.connected`. Signed out, tunnel down, every cluster dead: the menu
         bar still said the VPN was working (reported 2026-08-25).

         `menuBarState` already holds that line for `.connected`, which demands a cluster connected
         AND reachable rather than merely a tunnel interface being up. The icon has to hold it too,
         or the strictest state in the app is undone by the one pixel most people actually look at.

         `.attention` and `.off` now look the same, and that is the right trade: they are both "not
         carrying anything", and conflating those two is far cheaper than conflating attention with
         CONNECTED, which is not a shade of meaning but a false statement.
        */
        return state == .connected ? "MenuBarIcon" : "MenuBarIconOff"
    }
}

private struct MenuBarGlyphView: View {
    let state: MenuBarState
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activityFrame = 0

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(MenuBarIconAnimation.imageName(
                state: state,
                isActive: isActive,
                reduceMotion: reduceMotion,
                frame: activityFrame
            ))
            .renderingMode(.template)
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
        }
        .accessibilityLabel(accessibilityLabel)
        .task(id: AnimationTaskID(isActive: isActive, reduceMotion: reduceMotion)) {
            activityFrame = 0
            guard isActive, !reduceMotion else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(280))
                } catch {
                    return
                }
                activityFrame = (activityFrame + 1) % MenuBarIconAnimation.frameNames.count
            }
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .connected: .green
        case .attention: .orange
        case .off: .secondary
        }
    }

    private var accessibilityLabel: String {
        if isActive {
            return "RunOS working"
        }
        return switch state {
        case .connected: "RunOS connected"
        case .attention: "RunOS needs attention"
        case .off: "RunOS VPN off"
        }
    }

    private struct AnimationTaskID: Equatable {
        let isActive: Bool
        let reduceMotion: Bool
    }
}

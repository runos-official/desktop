import SwiftUI
import ServiceManagement

@main
@MainActor
struct RunOSDesktopApp: App {
    @StateObject private var coordinator: RefreshCoordinator
    @StateObject private var loginItem = LoginItemController()

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
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, loginItem: loginItem)
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
        return state == .off ? "MenuBarIconOff" : "MenuBarIcon"
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

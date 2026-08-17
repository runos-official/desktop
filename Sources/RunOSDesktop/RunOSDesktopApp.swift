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
        _coordinator = StateObject(wrappedValue: RefreshCoordinator(store: store, runner: runner))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, loginItem: loginItem)
                .onAppear { coordinator.start() }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image("MenuBarIcon")
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
            }
            .accessibilityLabel(accessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }

    private var indicatorColor: Color {
        switch coordinator.store.menuBarState {
        case .connected: .green
        case .attention: .orange
        case .off: .secondary
        }
    }

    private var accessibilityLabel: String {
        switch coordinator.store.menuBarState {
        case .connected: "RunOS connected"
        case .attention: "RunOS needs attention"
        case .off: "RunOS VPN off"
        }
    }
}

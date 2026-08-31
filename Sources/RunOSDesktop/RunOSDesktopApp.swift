import AppKit
import SwiftUI
import ServiceManagement

@main
@MainActor
struct RunOSDesktopApp: App {
    @StateObject private var coordinator: RefreshCoordinator
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var startupConnect: StartupConnectController

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
        /*
         ONE controller for the whole app. The menu toggle and the coordinator have to read the same
         setting, and two instances would each hold their own @Published copy: toggling the menu
         would leave the coordinator still believing the old value until the next launch.
        */
        let autoConnect = StartupConnectController()
        _startupConnect = StateObject(wrappedValue: autoConnect)
        let coordinator = RefreshCoordinator(store: store, runner: runner, autoConnect: autoConnect)
        _coordinator = StateObject(wrappedValue: coordinator)
        coordinator.start()
        // At app start, if the person asked for it. The coordinator connects again when a sign-in
        // completes, which is the case this alone used to miss (see AutoConnect).
        if autoConnect.isEnabled {
            coordinator.connectVPNAtStartup()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: coordinator, loginItem: loginItem, startupConnect: startupConnect)
        } label: {
            MenuBarGlyphView(
                state: coordinator.store.menuBarState,
                isActive: coordinator.store.isBusy,
                updateAvailable: coordinator.store.updateAvailable
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

enum MenuBarIconAnimation {
    static let frameNames = ["MenuBarActivity1", "MenuBarActivity2", "MenuBarActivity3"]

    /// Menu bar glyphs are 18pt; the badge is a third of that, which is the smallest an
    /// exclamation stays legible at 2x.
    private static let badgeSize: CGFloat = 6.5

    /*
     The glyph, with the update badge drawn INTO it.

     It has to be one bitmap. `MenuBarExtra` renders its label into a fixed template image, so
     anything laid over the glyph in SwiftUI is discarded: measured 2026-08-31, the icon was
     pixel-identical with the badge on and off while the app's own state was correct.

     The result is marked NON-template so the badge keeps its colour. The glyph itself is drawn
     through `NSImage.tint` at the menu bar's own label colour, so it still follows light and dark;
     losing template treatment would otherwise leave it black on a dark bar.
    */
    static func badgedImage(name: String, updateAvailable: Bool) -> NSImage {
        let base = NSImage(named: name) ?? NSImage()
        guard updateAvailable else {
            base.isTemplate = true
            return base
        }
        let size = base.size
        let composed = NSImage(size: size)
        composed.lockFocus()
        // The glyph, tinted the way a template image would have been.
        base.isTemplate = true
        NSColor.labelColor.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceOver)
        base.draw(at: .zero, from: NSRect(origin: .zero, size: size), operation: .destinationIn, fraction: 1)

        // The badge, top trailing, diagonally opposite where the connection dot used to be drawn.
        let rect = NSRect(x: size.width - badgeSize, y: size.height - badgeSize, width: badgeSize, height: badgeSize)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: rect).fill()
        /*
         The exclamation, WHITE on the orange.

         A template NSImage ignores a colour set with `set()` and drawn `sourceOver`: it keeps its
         own black, which is what the first attempt produced. Tinting one means filling the colour
         and masking it back with `.destinationIn`, the same trick used for the glyph above.
        */
        if let mark = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil) {
            let inset = rect.insetBy(dx: badgeSize * 0.36, dy: badgeSize * 0.20)
            let white = NSImage(size: inset.size)
            white.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: inset.size).fill()
            mark.draw(in: NSRect(origin: .zero, size: inset.size), from: .zero,
                      operation: .destinationIn, fraction: 1)
            white.unlockFocus()
            white.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)
        }
        composed.unlockFocus()
        composed.isTemplate = false
        return composed
    }

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
    /// An update is waiting for the CLI or the app. A SEPARATE signal from the connection dot below
    /// it: an update is not a VPN problem, and a disconnected VPN must not hide that one is waiting.
    let updateAvailable: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activityFrame = 0

    var body: some View {
        /*
         ONE COMPOSED IMAGE, not a glyph with things laid over it.

         MEASURED 2026-08-31. A ZStack here drew a coloured connection dot at bottomTrailing, and it
         has never been visible: `MenuBarExtra` renders its label into a fixed template image, so an
         overlay outside the glyph's own bounds is discarded and colour is flattened away. Captured
         the menu bar with the badge on and off, VPN state held constant, and the two bitmaps were
         pixel-identical while the accessibility label correctly said "update available".

         So the badge is drawn INTO the bitmap, and the image is marked non-template so its colour
         survives. What actually conveys connection today is the glyph swap (MenuBarIcon vs
         MenuBarIconOff), which is why that has always worked.
        */
        Image(nsImage: MenuBarIconAnimation.badgedImage(
            name: MenuBarIconAnimation.imageName(
                state: state,
                isActive: isActive,
                reduceMotion: reduceMotion,
                frame: activityFrame
            ),
            updateAvailable: updateAvailable
        ))

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

    private var accessibilityLabel: String {
        // The update is said in words, because the badge itself is 8 points of orange and a
        // screen reader gets nothing from it.
        let suffix = updateAvailable ? ", update available" : ""
        if isActive {
            return "RunOS working" + suffix
        }
        let base: String = switch state {
        case .connected: "RunOS connected"
        case .attention: "RunOS needs attention"
        case .off: "RunOS VPN off"
        }
        return base + suffix
    }

    private struct AnimationTaskID: Equatable {
        let isActive: Bool
        let reduceMotion: Bool
    }
}

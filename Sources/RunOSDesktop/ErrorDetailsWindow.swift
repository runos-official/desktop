import AppKit
import SwiftUI

/*
 The whole of a message the menu had to shorten.

 The menu shows one short line and offers Show Details; this is what that opens. It wraps, scrolls
 and can be selected and copied, so a long CLI sentence is readable to its last word, which is
 usually the part that says what to do (FCR 1730).
*/
@MainActor
final class ErrorDetailsWindowController: NSObject {
    static let shared = ErrorDetailsWindowController()
    private var window: NSPanel?

    func show(_ text: String) {
        let panel = window ?? makePanel()
        window = panel
        panel.contentView = NSHostingView(rootView: ErrorDetailsView(text: ErrorPresentation.fullText(text)) { [weak self] in
            self?.window?.close()
        })
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "RunOS Details"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 360, height: 200)
        return panel
    }
}

struct ErrorDetailsView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Close", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 200)
    }
}

import AppKit
import SwiftUI

/// Huddle's one window: kept under a fixed name, opened again if it doesn't come back at launch,
/// and brought back from Window ▸ Huddle after it has been closed.
///
/// macOS reopens an app's windows as they were left, finding each by the name it was saved
/// under. Without a fixed one, SwiftUI names the window after the type of the view the scene
/// shows, so a change to that view in an update renames it: the saved window then matches
/// nothing, and SwiftUI, taking the windows as restored, opens none at all. The fixed name
/// prevents that from now on; the check at launch covers the update that brings it in, and
/// any other time no window comes back.
@MainActor
enum MainWindow {
    static let id = "main"

    /// SwiftUI's way to open the window, handed over by `MainWindowCommand`, which can read it.
    fileprivate static var open: OpenWindowAction?

    /// Brings the window forward, or opens it if it is closed.
    static func show() {
        if let window = NSApp.windows.first(where: isShowing) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?(id: id)
        }
    }

    /// Whether this is Huddle's window, open (in view or in the Dock).
    static func isShowing(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(id) == true && (window.isVisible || window.isMiniaturized)
    }
}

/// Window ▸ Huddle (⌘0), as Messages has it. Made with the menus at launch, before there may be
/// any window, it also gives `MainWindow` the action that opens one.
struct MainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindow.open = openWindow
        return Button(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Huddle") {
            MainWindow.show()
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One window, without tabs: a second, from a tab bar's "+", would show the same account.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // By now macOS has put back what windows it could. If Huddle's isn't among them, it
        // never will be, and the app would sit there with only its menu bar: open it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: MainWindow.isShowing) { MainWindow.show() }
            }
        }
    }
}

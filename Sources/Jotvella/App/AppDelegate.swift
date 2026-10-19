import AppKit

/// Bridges AppKit reopen events (Dock click, Finder relaunch) back to SwiftUI so
/// the main window can be recreated after every window has been closed.
@MainActor
enum WindowLaunchCoordinator {
    static var openMainWindow: (() -> Void)?
}

@MainActor
final class JotvellaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        DispatchQueue.main.async {
            if let window = sender.windows.first(where: { $0.canBecomeKey }) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            } else {
                WindowLaunchCoordinator.openMainWindow?()
            }
            sender.activate(ignoringOtherApps: true)
        }
        return false
    }
}

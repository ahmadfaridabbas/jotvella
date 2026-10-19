import SwiftUI
import AppKit

@main
struct JotvellaApp: App {
    @NSApplicationDelegateAdaptor(JotvellaAppDelegate.self) private var appDelegate
    @StateObject private var store = NotebookStore()
    @AppStorage("appearance") private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(id: "main") {
            JotvellaWindow()
                .environmentObject(store)
                .onAppear { applyAppearance(appearance) }
                .onChange(of: appearance) { newValue in
                    applyAppearance(newValue)
                }
                .onChange(of: scenePhase) { phase in
                    if phase != .active { store.saveNow() }
                }
                .frame(minWidth: 960, minHeight: 650)
        }
        .commands {
            CommandGroup(after: .windowList) {
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Page") { store.addPage() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: [.command])
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: [.command])
                Button("Paste") {
                    // Let the focused editor handle paste so image insertion can use its caret.
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command])
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.saveNow() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
    }

    private func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

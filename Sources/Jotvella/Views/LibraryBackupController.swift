import AppKit
import UniformTypeIdentifiers

/// The panels and alerts for backing up and restoring the library. Used by the File menu and the toolbar.
@MainActor
enum LibraryBackupController {
    static func backUp(_ store: NotebookStore) {
        let panel = NSSavePanel()
        panel.title = "Back Up Library"
        panel.message = "Save a copy of all notebooks, pages and pictures."
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = NotebookStore.backupFileName(prefix: "Jotvella Backup")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let info = try await store.createBackup(to: destination)
                let alert = NSAlert()
                alert.messageText = "Backup saved"
                alert.informativeText = "\(summary(info)) were saved to \(destination.lastPathComponent)."
                alert.addButton(withTitle: "Show in Finder")
                alert.addButton(withTitle: "Done")
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            } catch {
                show(error, title: "The backup could not be saved")
            }
        }
    }

    static func restore(_ store: NotebookStore) {
        try? FileManager.default.createDirectory(at: store.backupsFolder, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.title = "Restore from Backup"
        panel.message = "Choose a Jotvella backup. Automatic backups are in the folder shown."
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = store.backupsFolder
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task {
            do {
                let prepared = try await NotebookStore.prepareBackup(at: source)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Restore this backup?"
                alert.informativeText = "Backup from \(prepared.info.created.formatted(date: .abbreviated, time: .shortened)) with \(summary(prepared.info)).\n\nThis replaces everything currently in Jotvella. Your current library is saved first as \u{201C}Jotvella Before Restore\u{201D} in the backups folder, so you can go back."
                alert.addButton(withTitle: "Restore")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    try? FileManager.default.removeItem(at: prepared.workDirectory)
                    return
                }
                try await store.restoreLibrary(from: prepared)
            } catch {
                show(error, title: "The backup could not be restored")
            }
        }
    }

    static func showBackupsInFinder(_ store: NotebookStore) {
        try? FileManager.default.createDirectory(at: store.backupsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.backupsFolder)
    }

    private static func summary(_ info: BackupInfo) -> String {
        "\(info.notebookCount) notebook\(info.notebookCount == 1 ? "" : "s") and \(info.pageCount) page\(info.pageCount == 1 ? "" : "s")"
    }

    private static func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

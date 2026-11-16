import Foundation

/// Describes a library backup. Stored inside the zip as `BackupInfo.json`.
struct BackupInfo: Codable, Equatable {
    var app = "Jotvella"
    var formatVersion = 1
    var appVersion: String
    var created: Date
    var notebookCount: Int
    var pageCount: Int
}

enum BackupError: LocalizedError {
    case notABackup
    case toolFailed(String)
    var errorDescription: String? {
        switch self {
        case .notABackup: "This file is not a Jotvella backup."
        case .toolFailed(let detail): "The backup archive could not be read or written. \(detail)"
        }
    }
}

/// Backing up and restoring the whole library as one zip: the notebook packages (text, tables,
/// tags, pictures) plus any legacy images, with a small `BackupInfo.json` describing it.
extension NotebookStore {
    /// Where automatic and safety backups are kept. A sibling of the library, so a backup never contains backups.
    var backupsFolder: URL { root.deletingLastPathComponent().appendingPathComponent("Jotvella Backups", isDirectory: true) }

    static func backupFileName(prefix: String, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(prefix) \(formatter.string(from: date)).zip"
    }

    // MARK: Create

    /// Saves pending edits, then writes the whole library to `destination` as a zip.
    @discardableResult
    func createBackup(to destination: URL) async throws -> BackupInfo {
        saveNow()
        let info = BackupInfo(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            created: .now,
            notebookCount: notebooks.count,
            pageCount: notebooks.reduce(0) { $0 + $1.sections.reduce(0) { $0 + $1.pages.count } }
        )
        let root = self.root
        let queue = persistenceQueue
        // Run on the persistence queue so a save can never rewrite files while they are being copied.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Self.writeBackup(root: root, destination: destination, info: info)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return info
    }

    nonisolated static func writeBackup(root: URL, destination: URL, info: BackupInfo) throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("JotvellaBackup-\(UUID().uuidString)", isDirectory: true)
        let staging = work.appendingPathComponent("Jotvella Backup", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }

        for name in ["Notebooks", "Images"] {
            let source = root.appendingPathComponent(name, isDirectory: true)
            if manager.fileExists(atPath: source.path) { try manager.copyItem(at: source, to: staging.appendingPathComponent(name, isDirectory: true)) }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: staging.appendingPathComponent("BackupInfo.json"))

        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: destination)
        try runTool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, destination.path])
    }

    nonisolated static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BackupError.toolFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Restore

    /// A backup that has been unpacked and checked, ready to be restored.
    struct PreparedBackup {
        let info: BackupInfo
        let folder: URL
        let workDirectory: URL
    }

    /// Unpacks a backup zip and checks that it is a Jotvella backup. Nothing is changed yet.
    nonisolated static func prepareBackup(at zip: URL) async throws -> PreparedBackup {
        try await Task.detached {
            let manager = FileManager.default
            let work = manager.temporaryDirectory.appendingPathComponent("JotvellaRestore-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: work, withIntermediateDirectories: true)
            do {
                try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let candidates = [work] + ((try? manager.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
                guard let folder = candidates.first(where: { manager.fileExists(atPath: $0.appendingPathComponent("BackupInfo.json").path) }),
                      manager.fileExists(atPath: folder.appendingPathComponent("Notebooks").path) else { throw BackupError.notABackup }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let info = try decoder.decode(BackupInfo.self, from: Data(contentsOf: folder.appendingPathComponent("BackupInfo.json")))
                guard info.app == "Jotvella" else { throw BackupError.notABackup }
                return PreparedBackup(info: info, folder: folder, workDirectory: work)
            } catch {
                try? manager.removeItem(at: work)
                throw error is BackupError ? error : BackupError.notABackup
            }
        }.value
    }

    /// Replaces the whole library with a prepared backup. The current library is first saved to the
    /// backups folder ("Before Restore"), so a restore can itself be undone by restoring that file.
    func restoreLibrary(from prepared: PreparedBackup) async throws {
        defer { try? FileManager.default.removeItem(at: prepared.workDirectory) }
        let manager = FileManager.default
        if !notebooks.isEmpty {
            try await createBackup(to: backupsFolder.appendingPathComponent(Self.backupFileName(prefix: "Jotvella Before Restore")))
        }
        saveNow()
        let root = self.root
        try persistenceQueue.sync {
            for name in ["Notebooks", "Images"] {
                let incoming = prepared.folder.appendingPathComponent(name, isDirectory: true)
                let target = root.appendingPathComponent(name, isDirectory: true)
                let staged = root.appendingPathComponent("\(name).restoring", isDirectory: true)
                try? manager.removeItem(at: staged)
                if manager.fileExists(atPath: incoming.path) { try manager.copyItem(at: incoming, to: staged) } else { try manager.createDirectory(at: staged, withIntermediateDirectories: true) }
                try? manager.removeItem(at: target)
                try manager.moveItem(at: staged, to: target)
            }
        }
        notebooks = Self.joiningAdjacentPlainTextBlocks(in: loadNotebookPackages() ?? [])
        selectedNotebook = nil
        selectedSection = nil
        selectedPage = nil
        selectFirstPage()
    }

    // MARK: Automatic backups

    /// Writes one backup a day (when the app starts or comes to the front), keeping the newest seven.
    func runAutomaticBackupIfNeeded(keeping limit: Int = 7) {
        guard !notebooks.isEmpty, !automaticBackupInProgress else { return }
        let prefix = "Jotvella Auto Backup"
        let manager = FileManager.default
        let existing = ((try? manager.contentsOfDirectory(at: backupsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "zip" }
            .map { (url: $0, date: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.date > $1.date }
        if let newest = existing.first, Date().timeIntervalSince(newest.date) < 20 * 3600 { return }

        automaticBackupInProgress = true
        let destination = backupsFolder.appendingPathComponent(Self.backupFileName(prefix: prefix))
        Task {
            defer { automaticBackupInProgress = false }
            guard (try? await createBackup(to: destination)) != nil else { return }
            for old in existing.dropFirst(max(0, limit - 1)) { try? manager.removeItem(at: old.url) }
        }
    }
}

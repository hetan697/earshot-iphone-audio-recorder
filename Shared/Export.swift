import Foundation

/// Copies finished recordings into a folder the person picked once in iCloud Drive. Audio first, info.json last: once info.json is there,
/// the folder is complete (docs/CONTRACT.md, iCloud channel).
enum Export {
    private static let failureFile = ".icloud-sync-error"
    private static let deletedFile = ".icloud-copy-deleted"
    private static var bookmarkFile: URL {
        Store.recordings.deletingLastPathComponent().appendingPathComponent("export-folder.bookmark")
    }

    static func setFolder(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.createDirectory(at: bookmarkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: bookmarkFile, options: .atomic)
    }

    static func clearFolder() { try? FileManager.default.removeItem(at: bookmarkFile) }

    /// The picked folder; recordings go into its 录音 subfolder (or into it, if it is the 录音 folder).
    static func folder() -> URL? {
        guard let data = try? Data(contentsOf: bookmarkFile) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale { try? setFolder(url) }
        return url
    }

    static var folderDisplayName: String? {
        folder().map { $0.lastPathComponent == "录音" ? "\($0.deletingLastPathComponent().lastPathComponent)/录音" : "\($0.lastPathComponent)/录音" }
    }

    static func isExported(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("exported.json").path)
    }

    static func failureMessage(in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(failureFile), encoding: .utf8)
    }

    static func wasDeleted(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(deletedFile).path)
    }

    /// Name the Mac sees: "2026-11-07 1033 现场对话".
    static func folderName(_ info: RecordingInfo) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(f.string(from: info.startedAt)) \(info.isConversation ? "现场对话" : "手机声音")"
    }

    /// Copies one finished recording. Returns true when it is (now or already) in the folder.
    @discardableResult
    static func copy(_ dir: URL, _ info: RecordingInfo, allowWiFiOnly: Bool = true) -> Bool {
        guard info.state != .recording || info.isStale(), !info.tracks.isEmpty else { return false }
        guard !wasDeleted(in: dir) else { return false }
        guard SyncPolicy.maySync else { return false }
        // The broadcast extension can outlive the app's last connectivity observation. In
        // Wi-Fi-only mode, only the foreground app may start an iCloud export.
        guard SyncPolicy.mode != .wifiOnly || allowWiFiOnly else { return false }
        if isExported(dir) {
            clearFailure(in: dir)
            return true
        }
        guard let picked = folder() else { return false }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let root = picked.lastPathComponent == "录音" ? picked : picked.appendingPathComponent("录音", isDirectory: true)
        let fm = FileManager.default
        var target = root.appendingPathComponent(folderName(info), isDirectory: true)
        if fm.fileExists(atPath: target.path) { target = root.appendingPathComponent("\(folderName(info)) \(info.id)") }

        var ok = true
        var copyError: String?
        var failure: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: &failure) { url in
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                for track in info.tracks.values {
                    try fm.copyItem(at: dir.appendingPathComponent(track.file), to: url.appendingPathComponent(track.file))
                }
                try fm.copyItem(at: dir.appendingPathComponent("info.json"), to: url.appendingPathComponent("info.json"))
            } catch {
                ok = false
                copyError = error.localizedDescription
                try? fm.removeItem(at: url)                    // never leave a half folder for the Mac
            }
        }
        guard ok, failure == nil else {
            saveFailure(copyError ?? failure?.localizedDescription ?? "无法复制到 iCloud 文件夹", in: dir)
            Store.notifyChanged()
            return false
        }
        let marker = ["name": target.lastPathComponent, "root": root.standardizedFileURL.path]
        do {
            let data = try JSONSerialization.data(withJSONObject: marker)
            try data.write(to: dir.appendingPathComponent("exported.json"), options: .atomic)
            clearFailure(in: dir)
        } catch {
            saveFailure(error.localizedDescription, in: dir)
            Store.notifyChanged()
            return false
        }
        Store.notifyChanged()
        return true
    }

    private static func saveFailure(_ message: String, in dir: URL) {
        try? message.write(to: dir.appendingPathComponent(failureFile), atomically: true, encoding: .utf8)
    }

    private static func clearFailure(in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(failureFile))
    }

    static func removeCopy(_ dir: URL) throws {
        let markerURL = dir.appendingPathComponent("exported.json")
        guard isExported(dir) else { return }
        let markerData = try Data(contentsOf: markerURL)
        guard let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: String],
              let name = marker["name"], !name.isEmpty,
              URL(fileURLWithPath: name).lastPathComponent == name,
              name != ".", name != ".." else {
            throw NSError(domain: "Earshot", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取 iCloud 副本位置"])
        }
        guard let picked = folder() else {
            throw NSError(domain: "Earshot", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "请先在设置中重新选择 iCloud 文件夹"])
        }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let root = picked.lastPathComponent == "录音" ? picked : picked.appendingPathComponent("录音", isDirectory: true)
        if let savedRoot = marker["root"],
           URL(fileURLWithPath: savedRoot).standardizedFileURL != root.standardizedFileURL {
            throw NSError(domain: "Earshot", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "此录音同步到另一个 iCloud 文件夹；请先在设置中选回原文件夹再删除"])
        }
        let target = root.appendingPathComponent(name, isDirectory: true)
        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                removalError = error
            }
        }
        if let removalError { throw removalError }
        if let coordinationError { throw coordinationError }
        try Data().write(to: dir.appendingPathComponent(deletedFile), options: .atomic)
        try FileManager.default.removeItem(at: markerURL)
        clearFailure(in: dir)
        Store.notifyChanged()
    }

    static func allowCopyAgain(in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(deletedFile))
    }

    /// Everything finished but not yet copied (the extension may not reach the folder, or none was picked then).
    static func copyPending() {
        guard folder() != nil, SyncPolicy.maySync else { return }
        for (dir, info) in Store.all() where !isExported(dir) { copy(dir, info) }
    }
}

/// A second copy under Documents is visible in Files > On My iPhone > Earshot.
enum LocalArchive {
    private static let failureFile = ".files-copy-error"
    private static let deletedFile = ".files-copy-deleted"
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Earshot", isDirectory: true)
    }

    static func recordingDirectory(_ info: RecordingInfo) -> URL {
        root.appendingPathComponent("\(Export.folderName(info)) \(info.id)", isDirectory: true)
    }

    static func balancedMixURL(_ info: RecordingInfo) -> URL {
        recordingDirectory(info).appendingPathComponent("balanced.m4a")
    }

    static func balancedMixPreferenceURL(_ info: RecordingInfo) -> URL {
        recordingDirectory(info).appendingPathComponent(".balanced-settings.json")
    }

    static func failureMessage(in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(failureFile), encoding: .utf8)
    }

    static func wasDeleted(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(deletedFile).path)
    }

    static func hasCopy(_ info: RecordingInfo) -> Bool {
        let directory = recordingDirectory(info)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("info.json").path)
            && info.tracks.values.allSatisfy {
                FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path)
            }
    }

    static func hasAnyCopy(_ info: RecordingInfo) -> Bool {
        FileManager.default.fileExists(atPath: recordingDirectory(info).path)
    }

    static func removeCopy(_ info: RecordingInfo, suppressingFutureCopyAt sourceDir: URL? = nil) throws {
        let directory = recordingDirectory(info)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        if let sourceDir {
            try Data().write(to: sourceDir.appendingPathComponent(deletedFile), options: .atomic)
        }
    }

    static func allowCopyAgain(in dir: URL) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(deletedFile))
    }

    static func copy(_ dir: URL, _ info: RecordingInfo) {
        guard info.state != .recording || info.isStale(), !info.tracks.isEmpty else { return }
        guard !wasDeleted(in: dir) else { return }
        let fm = FileManager.default
        let target = recordingDirectory(info)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for track in info.tracks.values {
                let source = dir.appendingPathComponent(track.file)
                let destination = target.appendingPathComponent(track.file)
                if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: source, to: destination) }
            }
            for name in ["info.json", "mac.json", "summary.md", "transcript.md", "纪要.md", "文字稿.md", "文字稿.srt"] {
                let source = dir.appendingPathComponent(name)
                let destination = target.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) { try? fm.removeItem(at: destination); try fm.copyItem(at: source, to: destination) }
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(failureFile))
        } catch {
            try? error.localizedDescription.write(to: dir.appendingPathComponent(failureFile), atomically: true, encoding: .utf8)
        }
    }
}

import Foundation
import SwiftUI

struct Recording: Identifiable, Equatable {
    var info: RecordingInfo
    var mac: MacInfo?
    var dir: URL
    var bytes: Int64
    var id: String { info.id }

    var isLive: Bool { info.state == .recording && !info.isStale() }
    var title: String { mac?.title ?? (info.isConversation ? "现场对话" : "手机声音") }
    func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
}

/// The recordings in the App Group container, newest first. Reloads when the extension starts or ends a
/// recording (Darwin notification) and whenever the app comes to the front.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var items: [Recording] = []

    var liveBroadcast: Recording? { items.first { $0.isLive && !$0.info.isConversation } }

    init() {
        if ProcessInfo.processInfo.arguments.contains("-EarshotDemo") { Demo.seed() }
        _ = Connectivity.shared
        Store.migrateLegacy()
        MicRecorder.shared.closeOrphans()
        reload()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let library = Unmanaged<Library>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in library.reload() }
        }, Store.changed as CFString, nil, .deliverImmediately)
    }

    func reload() {
        let fm = FileManager.default
        let mixPreference = MixPreference.load()
        let mixSignature = mixPreference.signature ?? Data()
        let dirs = (try? fm.contentsOfDirectory(at: Store.recordings, includingPropertiesForKeys: nil)) ?? []
        items = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")),
                  let info = try? Store.decoder.decode(RecordingInfo.self, from: data) else { return nil }
            let mac = (try? Data(contentsOf: dir.appendingPathComponent("mac.json")))
                .flatMap { try? Store.decoder.decode(MacInfo.self, from: $0) }
            let bytes = info.tracks.values.reduce(Int64(0)) { sum, t in
                let attrs = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(t.file).path)
                return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return Recording(info: info, mac: mac, dir: dir, bytes: bytes)
        }
        .sorted { $0.id > $1.id }
        for item in items {
            LocalArchive.copy(item.dir, item.info)
            guard !item.isLive,
                  item.info.tracks["app"] != nil, item.info.tracks["mic"] != nil else { continue }
            let output = LocalArchive.balancedMixURL(item.info)
            let settingsURL = LocalArchive.balancedMixPreferenceURL(item.info)
            let savedSignature = try? Data(contentsOf: settingsURL)
            guard !fm.fileExists(atPath: output.path) || savedSignature != mixSignature else { continue }
            let directory = output.deletingLastPathComponent()
            let marker = directory.appendingPathComponent(".mixing", isDirectory: true)
            if let attrs = try? fm.attributesOfItem(atPath: marker.path),
               let modified = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 6 * 60 * 60 {
                try? fm.removeItem(at: marker) // Recover if iOS stopped the app during a long export.
            }
            do { try fm.createDirectory(at: marker, withIntermediateDirectories: false) }
            catch { continue } // Another reload already started this mix.

            Task.detached(priority: .utility) {
                let temporary = directory.appendingPathComponent(".balanced-\(UUID().uuidString).m4a")
                defer { try? fm.removeItem(at: marker) }
                do {
                    try await AudioMix.exportBalanced(item, preference: mixPreference, to: temporary)
                    try? fm.removeItem(at: output)
                    try fm.moveItem(at: temporary, to: output)
                    try mixSignature.write(to: settingsURL, options: .atomic)
                } catch {
                    try? fm.removeItem(at: temporary)
                }
                if MixPreference.load().signature != mixSignature {
                    await MainActor.run { self.reload() }
                }
            }
        }
        objectWillChange.send() // refresh row delivery state after local archive attempts
    }

    func delete(ids: Set<String>, fromList: Bool, filesCopy: Bool, iCloudCopy: Bool) throws {
        let selected = items.filter { ids.contains($0.id) }
        do {
            if filesCopy {
                for item in selected {
                    try LocalArchive.removeCopy(item.info, suppressingFutureCopyAt: fromList ? nil : item.dir)
                }
            }
            if iCloudCopy {
                for item in selected { try Export.removeCopy(item.dir) }
            }
            if fromList {
                for item in selected where FileManager.default.fileExists(atPath: item.dir.path) {
                    try FileManager.default.removeItem(at: item.dir)
                }
            }
        } catch {
            reload()
            throw error
        }
        reload()
    }

    func retryCopies(_ item: Recording) {
        guard !item.isLive else { return }
        LocalArchive.allowCopyAgain(in: item.dir)
        Export.allowCopyAgain(in: item.dir)
        LocalArchive.copy(item.dir, item.info)
        _ = Export.copy(item.dir, item.info)
        reload()
    }
}

enum Format {
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    static func minutes(_ s: Double) -> String {
        s < 60 ? "\(Int(s.rounded())) 秒" : s < 3600 ? "\(Int((s / 60).rounded())) 分钟"
            : String(format: "%.1f 小时", s / 3600)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm"
            : Calendar.current.isDateInYesterday(d) ? "昨天 HH:mm" : "M月d日 HH:mm"
        return f.string(from: d)
    }

    static func sources(_ info: RecordingInfo) -> String {
        switch (info.tracks["app"] != nil, info.tracks["mic"] != nil) {
        case (true, true): "手机声音 + 麦克风"
        case (true, false): "手机声音"
        case (false, true): "麦克风"
        case (false, false): "没有录到声音"
        }
    }
}

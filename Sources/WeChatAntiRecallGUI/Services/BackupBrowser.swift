import Foundation

struct BackupEntry: Identifiable, Hashable {
    let id = UUID()
    let backupURL: URL
    /// Relative path of the binary this backup restores, e.g. "Contents/Resources/wechat.dylib".
    let binaryRelativePath: String
    let timestamp: String        // "YYYYMMDD-HHMMSS"
    let originalFileName: String  // e.g. "wechat.dylib"
    let sizeBytes: Int

    var displayName: String { originalFileName }
}

struct BackupSession: Identifiable {
    let id: String               // the timestamp
    let timestamp: String
    let entries: [BackupEntry]

    /// Human date like "2026-05-05 14:30:00" parsed from the "YYYYMMDD-HHMMSS" stamp.
    var displayDate: String {
        let inFormatter = DateFormatter()
        inFormatter.locale = Locale(identifier: "en_US_POSIX")
        inFormatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let date = inFormatter.date(from: timestamp) else { return timestamp }
        let outFormatter = DateFormatter()
        outFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return outFormatter.string(from: date)
    }
}

enum BackupBrowser {
    private static let marker = ".wechat-antirecall-backup-"

    /// Finds all backups next to patched binaries and groups them by install session
    /// (timestamp). Restoring a runtime-tip / multi-instance install requires restoring
    /// every binary from the same session, hence the grouping.
    static func sessions(appPath: String) -> [BackupSession] {
        let appURL = URL(fileURLWithPath: appPath)
        let searchDirs = [
            appURL.appendingPathComponent("Contents/Resources"),
            appURL.appendingPathComponent("Contents/MacOS"),
        ]

        var entries: [BackupEntry] = []
        let fm = FileManager.default
        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for url in items {
                let name = url.lastPathComponent
                guard let range = name.range(of: marker) else { continue }
                let originalName = String(name[name.startIndex..<range.lowerBound])
                let stamp = String(name[range.upperBound...])
                guard !originalName.isEmpty, !stamp.isEmpty else { continue }

                let relativeDir = dir.path.replacingOccurrences(of: appURL.path + "/", with: "")
                let binaryRelative = "\(relativeDir)/\(originalName)"
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                entries.append(BackupEntry(
                    backupURL: url,
                    binaryRelativePath: binaryRelative,
                    timestamp: stamp,
                    originalFileName: originalName,
                    sizeBytes: size
                ))
            }
        }

        let grouped = Dictionary(grouping: entries, by: \.timestamp)
        return grouped
            .map { BackupSession(id: $0.key, timestamp: $0.key, entries: $0.value.sorted { $0.originalFileName < $1.originalFileName }) }
            .sorted { $0.timestamp > $1.timestamp }   // newest first
    }
}

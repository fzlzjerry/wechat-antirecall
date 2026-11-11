import Foundation

// Opt-in export of the SQLCipher raw keys WeChat 4.x keeps in its heap. The runtime
// component (KeyExport.mm) scans its own memory from inside WeChat and snapshots
// them to keys.json in the app container; the CLI only flips the setting, reads the
// snapshot and pairs keys with database files for local readers (wx-cli's
// all_keys.json format). WeChat is sandboxed, so the file lives in its container.

struct KeyExportSettings: Codable, Equatable {
    static let preferenceKey = "WeChatAntiRecall_KeyExport"
    static let runtimeMarker = "WeChatAntiRecallKeyExport:1"
    var enabled = false
}

struct KeyExportKeyEntry: Codable, Equatable {
    let key: String
    let salt: String
}

struct KeyExportFile: Codable, Equatable {
    static let supportedVersion = 1

    let v: Int
    /// Unix seconds at which the runtime scanned the heap.
    let dumpedAt: Int64
    let keys: [KeyExportKeyEntry]
}

struct KeyExportReport: Encodable {
    let schemaVersion: Int
    let settings: KeyExportSettings
    let build: String
    let runtimeAvailable: Bool
    /// nil when keys.json cannot be read (for example without Full Disk Access).
    let keyCount: Int?
    let dumpedAt: Int64?
}

struct KeyExportListReport: Encodable {
    let schemaVersion: Int
    let dumpedAt: Int64
    let keys: [KeyExportKeyEntry]
}

struct KeyExportExportReport: Encodable {
    let schemaVersion: Int
    /// Absolute path of the written file.
    let output: String
    /// Database paths (relative to xwechat_files) that received a key.
    let matchedDatabases: [String]
    /// Salts in keys.json that matched no database on disk.
    let unmatchedKeySalts: [String]
    /// Encrypted databases whose salt matched no exported key.
    let encryptedDatabasesWithoutKey: Int
}

struct KeyExportOptions {
    enum Action: Equatable {
        case get, on, off, list, export
    }

    static let defaultOutputPath = "~/.wx-cli/all_keys.json"

    let action: Action
    let appPath: String
    let outputPath: String?
    let json: Bool

    init(_ arguments: [String]) throws {
        let actions: [String: Action] = ["get": .get, "on": .on, "off": .off, "list": .list, "export": .export]
        guard let name = arguments.first, let action = actions[name] else {
            throw ToolError.usage("key-export 需要 get、on、off、list 或 export。")
        }
        var app = "/Applications/WeChat.app"
        var output: String?
        var jsonOutput = false
        var seen: Set<String> = []
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw ToolError.usage("重复参数：\(flag)") }
            if flag == "--json" {
                jsonOutput = true
            } else if flag == "--app" || flag == "--output" {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ToolError.usage("\(flag) 需要一个值。")
                }
                if flag == "--app" {
                    app = arguments[index]
                } else {
                    output = arguments[index]
                }
            } else {
                throw ToolError.usage("未知参数：\(flag)")
            }
            index += 1
        }
        guard action == .export || output == nil else {
            throw ToolError.usage("--output 仅用于 key-export export。")
        }
        self.action = action
        appPath = app
        outputPath = output
        json = jsonOutput
    }

    func resolvedOutputURL() throws -> URL {
        let raw = outputPath ?? Self.defaultOutputPath
        let expanded = (raw as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            throw ToolError.usage("导出路径不能为空。")
        }
        return URL(fileURLWithPath: expanded, isDirectory: false)
    }
}

struct KeyExportPreferenceStore {
    // Shares the recall-tip store so writes go through cfprefsd and survive WeChat relaunches.
    let preferences: RecallTipPreferenceStore

    func load() throws -> KeyExportSettings {
        guard let value = try preferences.preferenceValue(forKey: KeyExportSettings.preferenceKey) else {
            return KeyExportSettings()
        }
        guard let dictionary = value as? [String: Any], let enabled = dictionary["enabled"] as? Bool else {
            throw ToolError.usage("密钥导出设置已损坏，请运行 key-export off 后重新开启。")
        }
        return KeyExportSettings(enabled: enabled)
    }

    func save(_ settings: KeyExportSettings) throws {
        try preferences.setPreferenceValue(
            ["enabled": settings.enabled], forKey: KeyExportSettings.preferenceKey)
    }
}

struct KeyExportFileStore {
    static let fileName = "keys.json"

    let directoryURL: URL

    init(homeDirectory: URL? = nil, domain: String) {
        let home = homeDirectory ?? RecallTipPreferenceStore.defaultHomeDirectory()
        directoryURL = home
            .appendingPathComponent("Library/Containers/\(domain)/Data/Library/Application Support/WeChatAntiRecall", isDirectory: true)
    }

    var keysURL: URL { directoryURL.appendingPathComponent(Self.fileName) }

    /// nil when no snapshot exists yet (the runtime only writes one after the user
    /// opts in and WeChat is logged in).
    func load() throws -> KeyExportFile? {
        let data: Data
        do {
            data = try Data(contentsOf: keysURL)
        } catch {
            if Self.isMissingFile(error) { return nil }
            throw Self.translate(error, operation: "读取", url: keysURL)
        }
        do {
            let file = try JSONDecoder().decode(KeyExportFile.self, from: data)
            guard file.v == KeyExportFile.supportedVersion else {
                throw ToolError.usage("keys.json 版本不受支持（v\(file.v)）。请更新工具后重新导出。")
            }
            return file
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.usage("keys.json 已损坏。请在微信运行并登录后重新执行 key-export on，等待一次扫描后再试。")
        }
    }

    private static func posixCode(_ error: Error) -> Int32? {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return nil
    }

    static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError) {
            return true
        }
        return posixCode(error) == ENOENT
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain
            && (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError) {
            return true
        }
        let code = posixCode(error)
        return code == EPERM || code == EACCES
    }

    private static func translate(_ error: Error, operation: String, url: URL) -> ToolError {
        if isPermissionDenied(error) {
            return .usage("没有权限\(operation)密钥快照：\(url.path)。请为运行本工具的应用开启「完全磁盘访问权限」，退出并重新打开后重试。")
        }
        return .fileOperationFailed(operation: "\(operation)密钥快照", path: url.path, underlying: error.localizedDescription)
    }
}

// Pairs the exported (key, salt) pairs with the SQLCipher database files under
// xwechat_files: each encrypted db starts with its 16-byte salt, so a salt match
// names the database a key opens. Same pairing local database scanners do; here it
// only reads files the user already owns.
struct KeyExportDatabaseMatcher {
    static let plainSQLiteHeader = Data("SQLite format 3".utf8)

    let rootURL: URL
    // Directory APIs hand back symlink-resolved URLs (/var → /private/var), so the
    // root is resolved the same way and relatives are computed per path component.
    private let resolvedRootComponents: [String]

    init(homeDirectory: URL? = nil, bundleIdentifier: String) {
        let home = homeDirectory ?? RecallTipPreferenceStore.defaultHomeDirectory()
        rootURL = home
            .appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Documents/xwechat_files", isDirectory: true)
        resolvedRootComponents = rootURL.resolvingSymlinksInPath().pathComponents
    }

    struct Result: Equatable {
        /// Database path relative to xwechat_files -> 64-hex enc_key.
        var matches: [String: String]
        /// Exported salts that matched no database on disk.
        var unmatchedKeySalts: [String]
        /// Encrypted databases whose salt matched no exported key.
        var encryptedDatabasesWithoutKey: Int
    }

    func match(keys: [KeyExportKeyEntry]) throws -> Result {
        var saltToDatabase: [String: String] = [:]
        var encryptedCount = 0
        for url in collectDatabaseURLs(from: rootURL) {
            guard let salt = try Self.readSalt(at: url) else { continue }
            guard let relative = Self.relativePath(of: url, under: resolvedRootComponents) else { continue }
            encryptedCount += 1
            saltToDatabase[salt] = relative
        }

        var matches: [String: String] = [:]
        var matchedSalts: Set<String> = []
        for entry in keys where !matchedSalts.contains(entry.salt) {
            guard let database = saltToDatabase[entry.salt] else { continue }
            matches[database] = entry.key
            matchedSalts.insert(entry.salt)
        }
        let unmatched = keys.map(\.salt).filter { !matchedSalts.contains($0) }
        return Result(
            matches: matches,
            unmatchedKeySalts: Array(Set(unmatched)).sorted(),
            encryptedDatabasesWithoutKey: encryptedCount - matches.count)
    }

    /// Path components of `url` below `rootComponents`, or nil when `url` does not
    /// actually live under the resolved root.
    static func relativePath(of url: URL, under rootComponents: [String]) -> String? {
        let components = url.resolvingSymlinksInPath().pathComponents
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func collectDatabaseURLs(from directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var collected: [URL] = []
        for url in contents {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                collected.append(contentsOf: collectDatabaseURLs(from: url))
            } else if url.pathExtension.lowercased() == "db" {
                collected.append(url)
            }
        }
        return collected
    }

    /// First 16 bytes as lowercased hex, or nil for plaintext SQLite databases and
    /// files too small to carry a salt.
    static func readSalt(at url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 16), header.count == 16 else { return nil }
        guard header.prefix(15) != plainSQLiteHeader else { return nil }
        return header.map { String(format: "%02x", $0) }.joined()
    }
}

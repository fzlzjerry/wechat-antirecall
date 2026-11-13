import Foundation

// Opt-in log of intercepted recalls. The runtime appends one JSON object per line from
// inside WeChat (RecallLog.mm); the CLI/GUI only read and clear it. WeChat is sandboxed,
// so the file lives in its container.

struct RecallLogSettings: Codable, Equatable {
    static let preferenceKey = "WeChatAntiRecall_RecallLog"
    static let runtimeMarker = "WeChatAntiRecallRecallLog:2"
    var enabled = false
}

struct RecallLogEntry: Codable, Equatable {
    static let supportedVersion = 1

    let version: Int
    /// Unix seconds at which this client observed the recall.
    let loggedAt: Int64
    /// `createtime` from the revoke XML, when present.
    let createTime: Int64?
    let session: String
    let msgId: String
    let newMsgId: String
    let notice: String
    /// Preview captured when the message arrived; nil when it was not seen this launch.
    let content: String?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case loggedAt, createTime, session, msgId, newMsgId, notice, content
    }
}

struct RecallLogReport: Encodable {
    let schemaVersion: Int
    let settings: RecallLogSettings
    let build: String
    let runtimeAvailable: Bool
    /// nil when the log cannot be read (for example without Full Disk Access).
    let entryCount: Int?
}

struct RecallLogListReport: Encodable {
    let schemaVersion: Int
    let entries: [RecallLogEntry]
    let total: Int
    let unreadableLines: Int
}

struct RecallLogOptions {
    enum Action: Equatable {
        case get, on, off, list, clear
    }

    static let defaultLimit = 200
    static let maximumLimit = 1000

    let action: Action
    let limit: Int
    let appPath: String
    let json: Bool

    init(_ arguments: [String]) throws {
        let actions: [String: Action] = ["get": .get, "on": .on, "off": .off, "list": .list, "clear": .clear]
        guard let name = arguments.first, let action = actions[name] else {
            throw ToolError.usage("recall-log 需要 get、on、off、list 或 clear。")
        }
        var app = "/Applications/WeChat.app"
        var limit: Int?
        var jsonOutput = false
        var seen: Set<String> = []
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw ToolError.usage("重复参数：\(flag)") }
            if flag == "--json" {
                jsonOutput = true
            } else if flag == "--app" || flag == "--limit" {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ToolError.usage("\(flag) 需要一个值。")
                }
                if flag == "--app" {
                    app = arguments[index]
                } else {
                    guard let value = Int(arguments[index]), (1...Self.maximumLimit).contains(value) else {
                        throw ToolError.usage("--limit 必须在 1 到 \(Self.maximumLimit) 之间。")
                    }
                    limit = value
                }
            } else {
                throw ToolError.usage("未知参数：\(flag)")
            }
            index += 1
        }
        guard action == .list || limit == nil else {
            throw ToolError.usage("--limit 仅用于 recall-log list。")
        }
        self.action = action
        self.limit = limit ?? Self.defaultLimit
        appPath = app
        json = jsonOutput
    }
}

struct RecallLogPreferenceStore {
    // Shares the recall-tip store so writes go through cfprefsd and survive WeChat relaunches.
    let preferences: RecallTipPreferenceStore

    func load() throws -> RecallLogSettings {
        guard let value = try preferences.preferenceValue(forKey: RecallLogSettings.preferenceKey) else {
            return RecallLogSettings()
        }
        guard let dictionary = value as? [String: Any], let enabled = dictionary["enabled"] as? Bool else {
            throw ToolError.usage("撤回记录设置已损坏，请运行 recall-log off 后重新开启。")
        }
        return RecallLogSettings(enabled: enabled)
    }

    func save(_ settings: RecallLogSettings) throws {
        try preferences.setPreferenceValue(
            ["enabled": settings.enabled], forKey: RecallLogSettings.preferenceKey)
    }
}

struct RecallLogFileStore {
    static let currentFileName = "recall-log.jsonl"
    static let rotatedFileName = "recall-log.1.jsonl"

    let directoryURL: URL

    init(homeDirectory: URL? = nil, domain: String) {
        let home = homeDirectory ?? RecallTipPreferenceStore.defaultHomeDirectory()
        directoryURL = home
            .appendingPathComponent("Library/Containers/\(domain)/Data/Library/Application Support/WeChatAntiRecall", isDirectory: true)
    }

    var currentURL: URL { directoryURL.appendingPathComponent(Self.currentFileName) }
    var rotatedURL: URL { directoryURL.appendingPathComponent(Self.rotatedFileName) }

    struct Snapshot: Equatable {
        /// Newest first, one entry per recalled message.
        var entries: [RecallLogEntry]
        var unreadableLines: Int
    }

    func load() throws -> Snapshot {
        var ordered: [RecallLogEntry] = []
        var unreadable = 0
        // The rotated file holds the older half, so reading it first keeps file order chronological.
        for url in [rotatedURL, currentURL] {
            guard let data = try readIfPresent(url) else { continue }
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                if let entry = try? JSONDecoder().decode(RecallLogEntry.self, from: Data(line)),
                   entry.version == RecallLogEntry.supportedVersion {
                    ordered.append(entry)
                } else {
                    unreadable += 1
                }
            }
        }
        // WeChat can re-deliver a revoke across launches; list each recalled message once.
        var seen: Set<String> = []
        var unique: [RecallLogEntry] = []
        for entry in ordered {
            if !entry.newMsgId.isEmpty, !seen.insert(entry.newMsgId).inserted { continue }
            unique.append(entry)
        }
        return Snapshot(entries: unique.reversed(), unreadableLines: unreadable)
    }

    /// Deletes both log files and returns how many entries were removed.
    @discardableResult
    func clear() throws -> Int {
        let removed = try load().entries.count
        for url in [currentURL, rotatedURL] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                if Self.isMissingFile(error) { continue }
                throw Self.translate(error, operation: "清空", url: url)
            }
        }
        return removed
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch {
            if Self.isMissingFile(error) { return nil }
            throw Self.translate(error, operation: "读取", url: url)
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
            return .usage("没有权限\(operation)撤回记录：\(url.path)。请为运行本工具的应用开启「完全磁盘访问权限」，退出并重新打开后重试。")
        }
        return .fileOperationFailed(operation: "\(operation)撤回记录", path: url.path, underlying: error.localizedDescription)
    }
}

import Foundation

// Opt-in notifications for incoming text messages that contain a configured keyword, even in
// chats WeChat keeps silent. The runtime (KeywordAlert.mm) reads these settings inside WeChat.

struct KeywordAlertSettings: Codable, Equatable {
    static let preferenceKey = "WeChatAntiRecall_KeywordAlert"
    static let runtimeMarker = "WeChatAntiRecallKeywordAlert:2"
    static let maximumKeywords = 20
    static let maximumKeywordLength = 32
    // The alert reads the same verified Message layout as the red-packet feature, so it is
    // available on exactly those builds.
    static var supportedBuilds: Set<String> { RedPacketSettings.supportedBuilds }

    var enabled = false
    var keywords: [String] = []

    /// Trims, validates and de-duplicates (ignoring case) user input. The runtime rejects the
    /// whole setting if a stored keyword breaks these rules, so they are enforced before saving.
    static func normalized(_ raw: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for item in raw {
            let keyword = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { throw ToolError.usage("关键词不能为空。") }
            guard keyword.utf16.count <= maximumKeywordLength else {
                throw ToolError.usage("关键词最长 \(maximumKeywordLength) 个字符：\(keyword)")
            }
            guard !keyword.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ToolError.usage("关键词不能包含控制字符。")
            }
            if seen.insert(keyword.lowercased()).inserted { result.append(keyword) }
        }
        guard result.count <= maximumKeywords else {
            throw ToolError.usage("最多支持 \(maximumKeywords) 个关键词。")
        }
        return result
    }

    func validate() throws {
        guard try Self.normalized(keywords) == keywords else {
            throw ToolError.usage("关键词设置无效，请重新保存。")
        }
        if enabled && keywords.isEmpty {
            throw ToolError.usage("开启关键词提醒前，请先设置至少一个关键词。")
        }
    }
}

struct KeywordAlertOptions {
    enum Action: Equatable {
        case get, on, off, set
    }

    let action: Action
    /// nil leaves the stored keywords untouched.
    let keywords: [String]?
    let appPath: String
    let json: Bool

    init(_ arguments: [String]) throws {
        let actions: [String: Action] = ["get": .get, "on": .on, "off": .off, "set": .set]
        guard let name = arguments.first, let action = actions[name] else {
            throw ToolError.usage("keyword-alert 需要 get、on、off 或 set。")
        }
        var app = "/Applications/WeChat.app"
        var keywords: [String] = []
        var sawKeyword = false
        var jsonOutput = false
        var seen: Set<String> = []
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--json" {
                guard seen.insert(flag).inserted else { throw ToolError.usage("重复参数：\(flag)") }
                jsonOutput = true
            } else if flag == "--app" || flag == "--keyword" {
                // --keyword may repeat; --app may not.
                if flag == "--app", !seen.insert(flag).inserted { throw ToolError.usage("重复参数：\(flag)") }
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ToolError.usage("\(flag) 需要一个值。")
                }
                if flag == "--app" {
                    app = arguments[index]
                } else {
                    sawKeyword = true
                    keywords.append(arguments[index])
                }
            } else {
                throw ToolError.usage("未知参数：\(flag)")
            }
            index += 1
        }
        guard action == .on || action == .set || !sawKeyword else {
            throw ToolError.usage("--keyword 仅用于 keyword-alert on 或 set。")
        }
        self.action = action
        // `set` with no keywords clears the list; `on` without any keeps what is stored.
        self.keywords = (action == .set || sawKeyword) ? try KeywordAlertSettings.normalized(keywords) : nil
        appPath = app
        json = jsonOutput
    }
}

struct KeywordAlertPreferenceStore {
    // Shares the recall-tip store so writes go through cfprefsd and survive WeChat relaunches.
    let preferences: RecallTipPreferenceStore

    func load() throws -> KeywordAlertSettings {
        guard let value = try preferences.preferenceValue(forKey: KeywordAlertSettings.preferenceKey) else {
            return KeywordAlertSettings()
        }
        guard let dictionary = value as? [String: Any],
              let enabled = dictionary["enabled"] as? Bool,
              let keywords = dictionary["keywords"] as? [String] else {
            throw ToolError.usage("关键词提醒设置已损坏，请运行 keyword-alert off 后重新设置。")
        }
        return KeywordAlertSettings(enabled: enabled, keywords: keywords)
    }

    func save(_ settings: KeywordAlertSettings) throws {
        try settings.validate()
        try preferences.setPreferenceValue(
            ["enabled": settings.enabled, "keywords": settings.keywords],
            forKey: KeywordAlertSettings.preferenceKey)
    }
}

struct KeywordAlertReport: Encodable {
    let schemaVersion: Int
    let settings: KeywordAlertSettings
    let supported: Bool
    let build: String
    let runtimeAvailable: Bool
}

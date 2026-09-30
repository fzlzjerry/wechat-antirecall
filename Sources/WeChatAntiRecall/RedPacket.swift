import Foundation

struct RedPacketSettings: Codable, Equatable {
    static let preferenceKey = "WeChatAntiRecall_RedPacket"
    static let supportedBuilds: Set<String> = ["269624", "269628", "270090", "270100", "270102"]
    static let runtimeMarker = "WeChatAntiRecallRedPacket:6"
    var enabled = false
    var delayMilliseconds = 500
    // true = 仅提醒：检测到红包只弹系统通知，不自动领取。
    var notifyOnly = false

    init(enabled: Bool = false, delayMilliseconds: Int = 500, notifyOnly: Bool = false) {
        self.enabled = enabled
        self.delayMilliseconds = delayMilliseconds
        self.notifyOnly = notifyOnly
    }

    // enabled/delayMilliseconds stay required, matching the runtime loader which
    // rejects incomplete dictionaries; only notifyOnly defaults for legacy files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        delayMilliseconds = try container.decode(Int.self, forKey: .delayMilliseconds)
        notifyOnly = try container.decodeIfPresent(Bool.self, forKey: .notifyOnly) ?? false
    }

    func validate() throws {
        guard (0...5000).contains(delayMilliseconds) else {
            throw ToolError.usage("红包等待时间必须在 0 到 5000 毫秒之间。")
        }
    }
}

struct RedPacketOptions {
    let enabled: Bool?
    let delayMilliseconds: Int?
    let notifyOnly: Bool?
    let appPath: String
    let json: Bool

    init(_ arguments: [String]) throws {
        guard let action = arguments.first, ["get", "on", "off"].contains(action) else {
            throw ToolError.usage("red-packet 需要 get、on 或 off。")
        }
        var app = "/Applications/WeChat.app"
        var delay: Int?
        var notifyOnly = false
        var jsonOutput = false
        var seen: Set<String> = []
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            guard seen.insert(flag).inserted else { throw ToolError.usage("重复参数：\(flag)") }
            if flag == "--json" {
                jsonOutput = true
            } else if flag == "--app" || flag == "--delay-ms" {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ToolError.usage("\(flag) 需要一个值。")
                }
                if flag == "--app" {
                    app = arguments[index]
                } else {
                    guard let value = Int(arguments[index]), (0...5000).contains(value) else {
                        throw ToolError.usage("红包等待时间必须在 0 到 5000 毫秒之间。")
                    }
                    delay = value
                }
            } else if flag == "--notify-only" {
                notifyOnly = true
            } else {
                throw ToolError.usage("未知参数：\(flag)")
            }
            index += 1
        }
        guard action == "on" || delay == nil else {
            throw ToolError.usage("--delay-ms 仅用于 red-packet on。")
        }
        guard action == "on" || !notifyOnly else {
            throw ToolError.usage("--notify-only 仅用于 red-packet on。")
        }
        if action == "on" && notifyOnly && delay != nil {
            throw ToolError.usage("仅提醒模式没有等待时间，--notify-only 不能与 --delay-ms 一起使用。")
        }
        enabled = action == "get" ? nil : action == "on"
        delayMilliseconds = delay
        self.notifyOnly = action == "on" ? notifyOnly : nil
        appPath = app
        json = jsonOutput
    }
}

struct RedPacketPreferenceStore {
    // Shares the recall-tip store so writes go through cfprefsd and survive WeChat relaunches.
    let preferences: RecallTipPreferenceStore

    var preferenceFileURL: URL { preferences.preferenceFileURL }

    func load() throws -> RedPacketSettings {
        guard let value = try preferences.preferenceValue(forKey: RedPacketSettings.preferenceKey) else {
            return RedPacketSettings()
        }
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let settings = try PropertyListDecoder().decode(RedPacketSettings.self, from: data)
        try settings.validate()
        return settings
    }

    func save(_ settings: RedPacketSettings) throws {
        try settings.validate()
        try preferences.setPreferenceValue([
            "enabled": settings.enabled,
            "delayMilliseconds": settings.delayMilliseconds,
            "notifyOnly": settings.notifyOnly
        ], forKey: RedPacketSettings.preferenceKey)
    }
}

struct RedPacketReport: Encodable {
    let schemaVersion: Int
    let settings: RedPacketSettings
    let supported: Bool
    let build: String
    let runtimeAvailable: Bool
}

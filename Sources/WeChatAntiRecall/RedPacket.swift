import Foundation

struct RedPacketSettings: Codable, Equatable {
    static let preferenceKey = "WeChatAntiRecall_RedPacket"
    static let supportedBuilds: Set<String> = ["269624", "269628", "270090", "270100"]
    static let runtimeMarker = "WeChatAntiRecallRedPacket:4"
    var enabled = false
    var delayMilliseconds = 500

    func validate() throws {
        guard (0...5000).contains(delayMilliseconds) else {
            throw ToolError.usage("红包等待时间必须在 0 到 5000 毫秒之间。")
        }
    }
}

struct RedPacketOptions {
    let enabled: Bool?
    let delayMilliseconds: Int?
    let appPath: String
    let json: Bool

    init(_ arguments: [String]) throws {
        guard let action = arguments.first, ["get", "on", "off"].contains(action) else {
            throw ToolError.usage("red-packet 需要 get、on 或 off。")
        }
        var app = "/Applications/WeChat.app"
        var delay: Int?
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
            } else {
                throw ToolError.usage("未知参数：\(flag)")
            }
            index += 1
        }
        guard action == "on" || delay == nil else {
            throw ToolError.usage("--delay-ms 仅用于 red-packet on。")
        }
        enabled = action == "get" ? nil : action == "on"
        delayMilliseconds = delay
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
            "delayMilliseconds": settings.delayMilliseconds
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

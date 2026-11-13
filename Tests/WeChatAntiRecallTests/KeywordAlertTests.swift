import XCTest
import Foundation
import WeChatAntiRecallRuntime
@testable import WeChatAntiRecall

final class KeywordAlertTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        folders = []
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyword-alert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func match(_ content: String, from: String = "wxid_friend", keywords: [String], type: UInt32 = 1) -> (keyword: String, snippet: String)? {
        guard let pointer = wechat_antirecall_keyword_alert_match_copy(type, from, content, keywords.joined(separator: "\n")) else { return nil }
        defer { wechat_antirecall_free(pointer) }
        let parts = String(cString: pointer).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }

    private func runtimeSettings(_ value: Any?) throws -> String? {
        let url = try makeFolder().appendingPathComponent("prefs.plist")
        let root: [String: Any] = value.map { ["WeChatAntiRecall_KeywordAlert": $0] } ?? ["Other": 1]
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
        guard let pointer = wechat_antirecall_keyword_alert_settings_for_plist_copy(url.path) else { return nil }
        defer { wechat_antirecall_free(pointer) }
        return String(cString: pointer)
    }

    // MARK: - Runtime settings

    func testRuntimeMarkerMatchesRuntimeExport() {
        XCTAssertEqual(String(cString: wechat_antirecall_keyword_alert_runtime_version()), KeywordAlertSettings.runtimeMarker)
        XCTAssertEqual(KeywordAlertSettings.runtimeMarker, "WeChatAntiRecallKeywordAlert:2")
    }

    func testRuntimeReadsValidSettings() throws {
        XCTAssertEqual(try runtimeSettings(["enabled": true, "keywords": ["红包", "Urgent"]]), "on\n红包\nUrgent")
        XCTAssertEqual(try runtimeSettings(["enabled": false, "keywords": ["红包"]]), "off\n红包")
        XCTAssertEqual(try runtimeSettings(["enabled": false, "keywords": [String]()]), "off")
    }

    func testRuntimeRejectsInvalidSettingsInsteadOfGuessing() throws {
        let tooMany = (0...KeywordAlertSettings.maximumKeywords).map { "k\($0)" }
        let cases: [(String, Any?)] = [
            ("missing", nil),
            ("not a dictionary", true),
            ("enabled is a number", ["enabled": 1, "keywords": ["a"]]),
            ("enabled is a string", ["enabled": "true", "keywords": ["a"]]),
            ("no keywords key", ["enabled": true]),
            ("keywords not an array", ["enabled": true, "keywords": "a"]),
            ("non-string keyword", ["enabled": true, "keywords": [1]]),
            ("empty keyword", ["enabled": true, "keywords": [""]]),
            ("padded keyword", ["enabled": true, "keywords": [" a"]]),
            ("control character", ["enabled": true, "keywords": ["a\u{7}b"]]),
            ("too long", ["enabled": true, "keywords": [String(repeating: "长", count: 33)]]),
            ("too many", ["enabled": true, "keywords": tooMany]),
            ("one bad keyword spoils the list", ["enabled": true, "keywords": ["ok", ""]]),
        ]
        for (name, value) in cases {
            XCTAssertNil(try runtimeSettings(value), name)
        }
    }

    func testRuntimeMissingOrBrokenPlistIsNotValid() throws {
        let folder = try makeFolder()
        XCTAssertNil(wechat_antirecall_keyword_alert_settings_for_plist_copy(folder.appendingPathComponent("missing.plist").path))
        let broken = folder.appendingPathComponent("broken.plist")
        try Data("nope".utf8).write(to: broken)
        XCTAssertNil(wechat_antirecall_keyword_alert_settings_for_plist_copy(broken.path))
    }

    // MARK: - Matching

    func testMatchesTextOnlyAndIgnoresOtherMessageTypes() {
        XCTAssertEqual(match("今天有红包吗", keywords: ["红包"])?.keyword, "红包")
        for type: UInt32 in [3, 34, 43, 47, 49, 10000, 10002] {
            XCTAssertNil(match("红包", keywords: ["红包"], type: type), "type \(type)")
        }
    }

    func testMatchingIgnoresCaseAndFullWidthAndKeepsConfiguredOrder() {
        XCTAssertEqual(match("this is URGENT now", keywords: ["urgent"])?.keyword, "urgent")
        XCTAssertEqual(match("ＡＢＣ在这里", keywords: ["abc"])?.keyword, "abc")
        XCTAssertEqual(match("紧急！有红包", keywords: ["红包", "紧急"])?.keyword, "红包",
                       "the first configured keyword wins, not the first one in the text")
        XCTAssertNil(match("没有关键内容", keywords: ["红包", "紧急"]))
        XCTAssertNil(match("红包", keywords: []))
        XCTAssertNil(match("红包", from: "", keywords: ["红包"]))
        XCTAssertNil(match("   \n  ", keywords: ["红包"]))
    }

    func testGroupSenderPrefixIsNotSearched() {
        XCTAssertNil(match("wxid_redpacket:\n你好", from: "123@chatroom", keywords: ["redpacket"]),
                     "a keyword must not match the sender id in the group prefix")
        XCTAssertEqual(match("wxid_a:\n群里有红包", from: "123@chatroom", keywords: ["红包"])?.keyword, "红包")
        // Without a chat room, "x:\ny" is just the message text.
        XCTAssertEqual(match("note:\n红包", from: "wxid_friend", keywords: ["note"])?.keyword, "note")
        // A group message without a recognizable prefix is still searched as a whole.
        XCTAssertEqual(match("没有前缀的红包", from: "123@chatroom", keywords: ["红包"])?.keyword, "红包")
    }

    func testSnippetIsOneBoundedLine() throws {
        let flat = try XCTUnwrap(match("第一行\n第二行\r\n第三行 红包", keywords: ["红包"])).snippet
        XCTAssertFalse(flat.contains("\n"))
        XCTAssertEqual(flat, "第一行 第二行 第三行 红包")

        let long = String(repeating: "字", count: 200) + "红包"
        let bounded = try XCTUnwrap(match(long, keywords: ["字"])).snippet
        XCTAssertEqual(bounded, String(repeating: "字", count: 80) + "…")

        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let cut = try XCTUnwrap(match(emoji + "红包", keywords: ["红包"])).snippet
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertEqual(cut.dropLast().count, 80, "cuts on whole characters, never inside a family emoji")
    }

    func testIgnoresMessagesTheAccountSentItself() {
        func addressed(_ account: String, _ from: String, _ to: String, _ content: String) -> Bool {
            wechat_antirecall_keyword_alert_addressed_to_others(account, from, to, content) == 1
        }
        XCTAssertTrue(addressed("wxid_me", "wxid_friend", "wxid_me", "红包"))
        XCTAssertTrue(addressed("wxid_me", "123@chatroom", "wxid_me", "wxid_other:\n红包"))
        XCTAssertFalse(addressed("wxid_me", "123@chatroom", "wxid_me", "wxid_me:\n红包"), "synced from my other device")
        XCTAssertFalse(addressed("wxid_me", "wxid_me", "wxid_friend", "红包"), "sent by me")
        XCTAssertFalse(addressed("wxid_me", "wxid_friend", "wxid_someone_else", "红包"), "not addressed to this account")
        XCTAssertFalse(addressed("", "wxid_friend", "wxid_me", "红包"), "unknown account never alerts")
        XCTAssertFalse(addressed("wxid_me", "", "wxid_me", "红包"))
    }

    // MARK: - CLI

    func testSupportedBuildsFollowTheVerifiedMessageLayout() {
        XCTAssertEqual(KeywordAlertSettings.supportedBuilds, RedPacketSettings.supportedBuilds)
        XCTAssertTrue(KeywordAlertSettings.supportedBuilds.contains("270135"))
    }

    func testKeywordNormalization() throws {
        XCTAssertEqual(try KeywordAlertSettings.normalized(["  红包 ", "Urgent", "urgent", "紧急\n"]), ["红包", "Urgent", "紧急"])
        XCTAssertEqual(try KeywordAlertSettings.normalized([]), [])
        for bad in [[""], ["   "], [String(repeating: "长", count: 33)], ["a\u{7}b"],
                    (0...KeywordAlertSettings.maximumKeywords).map { "k\($0)" }] {
            XCTAssertThrowsError(try KeywordAlertSettings.normalized(bad), "\(bad)")
        }
        XCTAssertNoThrow(try KeywordAlertSettings.normalized([String(repeating: "长", count: 32)]))
    }

    func testStrictCLIOptions() throws {
        let get = try KeywordAlertOptions(["get", "--json"])
        XCTAssertEqual(get.action, .get)
        XCTAssertNil(get.keywords)
        XCTAssertTrue(get.json)
        XCTAssertEqual(get.appPath, "/Applications/WeChat.app")

        let on = try KeywordAlertOptions(["on", "--keyword", " 红包 ", "--keyword", "紧急", "--app", "/tmp/WeChat.app"])
        XCTAssertEqual(on.action, .on)
        XCTAssertEqual(on.keywords, ["红包", "紧急"])
        XCTAssertEqual(on.appPath, "/tmp/WeChat.app")
        XCTAssertNil(try KeywordAlertOptions(["on"]).keywords, "on without keywords keeps the stored list")

        XCTAssertEqual(try KeywordAlertOptions(["set"]).keywords, [], "set without keywords clears the list")
        XCTAssertEqual(try KeywordAlertOptions(["set", "--keyword", "a"]).keywords, ["a"])

        for args in [[], ["enable"], ["get", "--keyword", "a"], ["off", "--keyword", "a"], ["on", "--keyword"],
                     ["on", "--keyword", "--json"], ["on", "--keyword", ""], ["get", "--json", "--json"],
                     ["on", "--app", "/a", "--app", "/b"], ["on", "--unknown"]] {
            XCTAssertThrowsError(try KeywordAlertOptions(args), "\(args)")
        }
    }

    func testPreferenceRoundTripKeepsOtherSettingsAndRejectsDamage() throws {
        let folder = try makeFolder()
        let store = KeywordAlertPreferenceStore(
            preferences: RecallTipPreferenceStore(homeDirectory: folder, domain: "com.tencent.xinWeChat"))
        XCTAssertEqual(try store.load(), KeywordAlertSettings(), "off by default")

        let plist = store.preferences.preferenceFileURL
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["Unrelated": "preserve"]
        try PropertyListSerialization.data(fromPropertyList: existing, format: .binary, options: 0).write(to: plist)

        try store.save(KeywordAlertSettings(enabled: true, keywords: ["红包", "Urgent"]))
        XCTAssertEqual(try store.load(), KeywordAlertSettings(enabled: true, keywords: ["红包", "Urgent"]))
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(saved["Unrelated"] as? String, "preserve")
        // What the CLI stores must be exactly what the runtime accepts.
        XCTAssertEqual(wechat_antirecall_keyword_alert_settings_for_plist_copy(plist.path).map { String(cString: $0) }, "on\n红包\nUrgent")

        let before = try Data(contentsOf: plist)
        XCTAssertThrowsError(try store.save(KeywordAlertSettings(enabled: true, keywords: [])), "enabled needs a keyword")
        XCTAssertThrowsError(try store.save(KeywordAlertSettings(enabled: false, keywords: [" padded"])))
        XCTAssertEqual(try Data(contentsOf: plist), before, "a rejected save leaves the stored value alone")

        let damaged: [String: Any] = ["WeChatAntiRecall_KeywordAlert": ["enabled": "yes"]]
        try PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0).write(to: plist)
        XCTAssertThrowsError(try store.load())
    }
}

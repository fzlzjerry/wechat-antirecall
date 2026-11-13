import XCTest
import Foundation
import WeChatAntiRecallRuntime
@testable import WeChatAntiRecall

final class RecallLogTests: XCTestCase {
    private var folders: [URL] = []

    override func setUp() {
        super.setUp()
        wechat_antirecall_recall_log_reset_for_test()
    }

    override func tearDown() {
        for folder in folders {
            // A test may leave an unreadable file behind on purpose.
            if let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
            try? FileManager.default.removeItem(at: folder)
        }
        folders = []
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func revokeXML(
        session: String = "wxid_fixture",
        msgId: String = "222",
        newMsgId: String = "9876543210123",
        notice: String = "<![CDATA[\"张三\" 撤回了一条消息]]>"
    ) -> String {
        "<sysmsg type=\"revokemsg\"><revokemsg><session>\(session)</session>"
            + "<oldmsgid>111</oldmsgid><msgid>\(msgId)</msgid><newmsgid>\(newMsgId)</newmsgid>"
            + "<createtime>1715563800</createtime><replacemsg>\(notice)</replacemsg></revokemsg></sysmsg>"
    }

    private func encode(xml: String, notice: String = "", content: String? = nil, loggedAt: UInt64 = 1_715_563_900) throws -> [String: Any] {
        let pointer = try XCTUnwrap(wechat_antirecall_recall_log_encode_copy(xml, notice, content, loggedAt))
        defer { wechat_antirecall_free(pointer) }
        let line = String(cString: pointer)
        XCTAssertFalse(line.contains("\n"), "one event must stay on one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    // MARK: - Runtime encoding

    func testRuntimeMarkerMatchesRuntimeExport() {
        XCTAssertEqual(String(cString: wechat_antirecall_recall_log_runtime_version()),
                       RecallLogSettings.runtimeMarker)
        XCTAssertEqual(RecallLogSettings.runtimeMarker, "WeChatAntiRecallRecallLog:2")
    }

    func testEncodesRevokeFieldsAndUnknownContentAsNull() throws {
        let object = try encode(xml: revokeXML(), notice: "\"张三\" 撤回了一条消息")
        XCTAssertEqual(object["v"] as? Int, 1)
        XCTAssertEqual(object["loggedAt"] as? Int, 1_715_563_900)
        XCTAssertEqual(object["createTime"] as? Int, 1_715_563_800)
        XCTAssertEqual(object["session"] as? String, "wxid_fixture")
        XCTAssertEqual(object["msgId"] as? String, "222")
        XCTAssertEqual(object["newMsgId"] as? String, "9876543210123")
        XCTAssertEqual(object["notice"] as? String, "\"张三\" 撤回了一条消息")
        XCTAssertTrue(object["content"] is NSNull, "a cold-cache miss is unknown, not an empty message")
    }

    func testEncodesContentWithSpecialCharactersOnOneLine() throws {
        let content = "第一行\n第二行 \"引号\" a/b\\c\t结尾"
        let object = try encode(xml: revokeXML(), notice: "n", content: content)
        XCTAssertEqual(object["content"] as? String, content)
    }

    func testFallsBackToReplaceMessageTagWhenNoticeIsMissing() throws {
        let cdata = try encode(xml: revokeXML())
        XCTAssertEqual(cdata["notice"] as? String, "\"张三\" 撤回了一条消息")
        let escaped = try encode(xml: revokeXML(notice: "&quot;李四&quot; 撤回了 &lt;一条&gt; 消息 &amp; 更多"))
        XCTAssertEqual(escaped["notice"] as? String, "\"李四\" 撤回了 <一条> 消息 & 更多")
    }

    func testOmitsNonNumericIdsAndMissingCreateTime() throws {
        let xml = "<sysmsg><revokemsg><session>room@chatroom</session><msgid>abc</msgid>"
            + "<newmsgid>12x</newmsgid></revokemsg></sysmsg>"
        let object = try encode(xml: xml, notice: "n")
        XCTAssertEqual(object["msgId"] as? String, "")
        XCTAssertEqual(object["newMsgId"] as? String, "")
        XCTAssertTrue(object["createTime"] is NSNull)
        XCTAssertEqual(object["session"] as? String, "room@chatroom")
    }

    func testTruncatesLongFieldsWithoutSplittingCharacters() throws {
        let content = String(repeating: "撤", count: 1000)
        let object = try encode(xml: revokeXML(), notice: "n", content: content)
        let stored = try XCTUnwrap(object["content"] as? String)
        XCTAssertTrue(stored.hasSuffix("…"))
        XCTAssertLessThanOrEqual(stored.utf8.count, 512 + 3)
        XCTAssertTrue(stored.dropLast().allSatisfy { $0 == "撤" })
    }

    func testInvalidUTF8InputStillProducesValidJSON() throws {
        let bytes: [CChar] = [0x61, CChar(bitPattern: 0xFF), CChar(bitPattern: 0xFE), 0x62, 0]
        let pointer = try XCTUnwrap(wechat_antirecall_recall_log_encode_copy(revokeXML(), bytes, nil, 1))
        defer { wechat_antirecall_free(pointer) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any])
        XCTAssertEqual(object["notice"] as? String, "<non-utf8>")
    }

    // MARK: - Runtime file writing

    func testRecordAppendsOnePrivateLinePerRecallAndSkipsDuplicates() throws {
        let directory = try makeFolder().appendingPathComponent("WeChatAntiRecall", isDirectory: true)
        let first = revokeXML(newMsgId: "1001")
        XCTAssertEqual(wechat_antirecall_recall_log_record_for_test(directory.path, first, "n1", "[图片]", 10), 1)
        XCTAssertEqual(wechat_antirecall_recall_log_record_for_test(directory.path, first, "n1", "[图片]", 11), 0,
                       "a re-delivered revoke must not be listed twice")
        XCTAssertEqual(wechat_antirecall_recall_log_record_for_test(directory.path, revokeXML(newMsgId: "1002"), "n2", nil, 12), 1)

        let log = directory.appendingPathComponent("recall-log.jsonl")
        XCTAssertEqual(try lines(of: log).count, 2)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testRotatesIntoSecondFileWhenLogIsFull() throws {
        let directory = try makeFolder()
        let current = directory.appendingPathComponent("recall-log.jsonl")
        let rotated = directory.appendingPathComponent("recall-log.1.jsonl")
        // Every line is 11 bytes with its newline, so a 20-byte limit rotates once a file holds two.
        for index in 0..<4 {
            XCTAssertEqual(wechat_antirecall_recall_log_append_for_test(directory.path, "{\"line\":\(index)}", 20), 1)
        }
        XCTAssertEqual(try lines(of: rotated), ["{\"line\":0}", "{\"line\":1}"])
        XCTAssertEqual(try lines(of: current), ["{\"line\":2}", "{\"line\":3}"])

        XCTAssertEqual(wechat_antirecall_recall_log_append_for_test(directory.path, "{\"line\":4}", 20), 1)
        XCTAssertEqual(try lines(of: rotated), ["{\"line\":2}", "{\"line\":3}"], "the older generation is replaced, not kept forever")
        XCTAssertEqual(try lines(of: current), ["{\"line\":4}"])
    }

    func testRefusesToFollowSymlinkedLog() throws {
        let directory = try makeFolder()
        let target = directory.appendingPathComponent("elsewhere.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("recall-log.jsonl"), withDestinationURL: target)
        XCTAssertEqual(wechat_antirecall_recall_log_append_for_test(directory.path, "{}", 1 << 20), 0)
        XCTAssertEqual(try String(contentsOf: target), "keep")
    }

    // MARK: - Production decision path

    private func setRuntimePreference(_ value: Any?) {
        // Clear first: preferences compare dictionaries with isEqual:, under which @YES equals
        // @1, so replacing {enabled: 1} with {enabled: true} would otherwise keep the old number.
        CFPreferencesSetAppValue(RecallLogSettings.preferenceKey as CFString, nil, kCFPreferencesCurrentApplication)
        // The test process is the "current application", the same lookup WeChat performs.
        CFPreferencesSetAppValue(RecallLogSettings.preferenceKey as CFString, value as CFPropertyList?, kCFPreferencesCurrentApplication)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    func testObservedRecallsAreOnlyWrittenWhenTheUserOptedIn() throws {
        let directory = try makeFolder().appendingPathComponent("WeChatAntiRecall", isDirectory: true)
        let log = directory.appendingPathComponent("recall-log.jsonl")
        defer { setRuntimePreference(nil) }

        setRuntimePreference(nil)
        wechat_antirecall_recall_log_observe_for_test(directory.path, revokeXML(newMsgId: "501"), "n", "c")
        wechat_antirecall_recall_log_flush_for_test()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "off by default: nothing may touch the disk")

        setRuntimePreference(["enabled": false])
        wechat_antirecall_recall_log_observe_for_test(directory.path, revokeXML(newMsgId: "502"), "n", "c")
        wechat_antirecall_recall_log_flush_for_test()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        setRuntimePreference(["enabled": 1])
        wechat_antirecall_recall_log_observe_for_test(directory.path, revokeXML(newMsgId: "503"), "n", "c")
        wechat_antirecall_recall_log_flush_for_test()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "only a real boolean counts as consent")

        setRuntimePreference(["enabled": true])
        wechat_antirecall_recall_log_observe_for_test(directory.path, revokeXML(newMsgId: "504"), "\"甲\" 撤回了一条消息", "[语音]")
        wechat_antirecall_recall_log_observe_for_test(directory.path, revokeXML(newMsgId: "504"), "\"甲\" 撤回了一条消息", "[语音]")
        wechat_antirecall_recall_log_flush_for_test()
        XCTAssertEqual(try lines(of: log).count, 1, "the earlier opted-out recalls were not remembered, and the repeat is skipped")

        setRuntimePreference(["enabled": false])
        wechat_antirecall_recall_log_observe_for_test(directory.path, revokeXML(newMsgId: "505"), "n", "c")
        wechat_antirecall_recall_log_flush_for_test()
        XCTAssertEqual(try lines(of: log).count, 1, "turning the log off takes effect without relaunching WeChat")
    }

    // MARK: - Settings

    func testRuntimeSettingRequiresStrictBooleanDictionary() throws {
        let folder = try makeFolder()
        func plist(_ value: Any?) throws -> String {
            let url = folder.appendingPathComponent(UUID().uuidString + ".plist")
            let root: [String: Any] = value.map { ["WeChatAntiRecall_RecallLog": $0] } ?? ["Other": 1]
            try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
            return url.path
        }
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist(["enabled": true])), 1)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist(["enabled": false])), 0)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist(["enabled": 1])), 0)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist(["enabled": "true"])), 0)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist([String: Any]())), 0)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist(true)), 0)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(try plist(nil)), 0, "off by default")
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(folder.appendingPathComponent("missing.plist").path), 0)
        let broken = folder.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: broken)
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(broken.path), 0)
    }

    func testStrictCLIOptions() throws {
        let get = try RecallLogOptions(["get", "--json"])
        XCTAssertEqual(get.action, .get)
        XCTAssertTrue(get.json)
        XCTAssertEqual(get.appPath, "/Applications/WeChat.app")
        let list = try RecallLogOptions(["list", "--limit", "50", "--app", "/tmp/WeChat.app"])
        XCTAssertEqual(list.action, .list)
        XCTAssertEqual(list.limit, 50)
        XCTAssertEqual(list.appPath, "/tmp/WeChat.app")
        XCTAssertEqual(try RecallLogOptions(["list"]).limit, RecallLogOptions.defaultLimit)
        for name in ["on", "off", "clear"] {
            XCTAssertNoThrow(try RecallLogOptions([name]))
        }
        for args in [[], ["enable"], ["get", "--limit", "10"], ["on", "--limit", "10"], ["list", "--limit", "0"],
                     ["list", "--limit", "1001"], ["list", "--limit", "x"], ["list", "--limit"],
                     ["get", "--json", "--json"], ["on", "--unknown"], ["clear", "--app"]] {
            XCTAssertThrowsError(try RecallLogOptions(args), "\(args)")
        }
    }

    func testPreferenceRoundTripKeepsOtherSettingsAndRejectsDamage() throws {
        let folder = try makeFolder()
        let store = RecallLogPreferenceStore(
            preferences: RecallTipPreferenceStore(homeDirectory: folder, domain: "com.tencent.xinWeChat"))
        XCTAssertEqual(try store.load(), RecallLogSettings(), "off by default")
        XCTAssertFalse(RecallLogSettings().enabled)

        let plist = store.preferences.preferenceFileURL
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = ["Unrelated": "preserve"]
        try PropertyListSerialization.data(fromPropertyList: existing, format: .binary, options: 0).write(to: plist)
        try store.save(RecallLogSettings(enabled: true))
        XCTAssertEqual(try store.load(), RecallLogSettings(enabled: true))
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        XCTAssertEqual(saved["Unrelated"] as? String, "preserve")
        XCTAssertEqual((saved["WeChatAntiRecall_RecallLog"] as? [String: Any])?["enabled"] as? Bool, true)
        // What the CLI stores must be exactly what the runtime accepts.
        XCTAssertEqual(wechat_antirecall_recall_log_enabled_for_plist(plist.path), 1)

        let damaged: [String: Any] = ["WeChatAntiRecall_RecallLog": ["enabled": "yes"]]
        try PropertyListSerialization.data(fromPropertyList: damaged, format: .binary, options: 0).write(to: plist)
        XCTAssertThrowsError(try store.load())
    }

    // MARK: - Reading the log

    private func fixtureLine(_ newMsgId: String, loggedAt: Int, notice: String = "n", content: String? = "c", version: Int = 1) -> String {
        let contentJSON = content.map { "\"\($0)\"" } ?? "null"
        return "{\"v\":\(version),\"loggedAt\":\(loggedAt),\"createTime\":null,\"session\":\"s\","
            + "\"msgId\":\"1\",\"newMsgId\":\"\(newMsgId)\",\"notice\":\"\(notice)\",\"content\":\(contentJSON)}"
    }

    func testMissingLogReadsAsEmpty() throws {
        let store = RecallLogFileStore(homeDirectory: try makeFolder(), domain: "com.tencent.xinWeChat")
        XCTAssertEqual(try store.load(), RecallLogFileStore.Snapshot(entries: [], unreadableLines: 0))
        XCTAssertEqual(try store.clear(), 0)
    }

    func testReadsNewestFirstAcrossRotationDedupesAndCountsUnreadableLines() throws {
        let store = RecallLogFileStore(homeDirectory: try makeFolder(), domain: "com.tencent.xinWeChat")
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try ([fixtureLine("1", loggedAt: 100), fixtureLine("2", loggedAt: 200)].joined(separator: "\n") + "\n")
            .write(to: store.rotatedURL, atomically: true, encoding: .utf8)
        try ([
            fixtureLine("2", loggedAt: 250),                 // re-delivered after a relaunch
            "this is not json",
            fixtureLine("9", loggedAt: 900, version: 2),     // written by a newer runtime
            fixtureLine("3", loggedAt: 300, content: nil),
            fixtureLine("", loggedAt: 400),                  // no newmsgid: cannot be matched, keep it
            "",
        ].joined(separator: "\n") + "\n").write(to: store.currentURL, atomically: true, encoding: .utf8)

        let snapshot = try store.load()
        XCTAssertEqual(snapshot.entries.map(\.loggedAt), [400, 300, 200, 100])
        XCTAssertEqual(snapshot.entries.map(\.newMsgId), ["", "3", "2", "1"])
        XCTAssertNil(snapshot.entries[1].content)
        XCTAssertEqual(snapshot.unreadableLines, 2)

        XCTAssertEqual(try store.clear(), 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.currentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rotatedURL.path))
        XCTAssertEqual(try store.load().entries.count, 0)
    }

    func testRuntimeWrittenLinesAreReadableByTheFileStore() throws {
        let store = RecallLogFileStore(homeDirectory: try makeFolder(), domain: "com.tencent.xinWeChat")
        XCTAssertEqual(wechat_antirecall_recall_log_record_for_test(
            store.directoryURL.path, revokeXML(session: "room@chatroom", newMsgId: "77"),
            "\"王五\" 撤回了一条消息", "[图片]", 1_715_563_900), 1)
        XCTAssertEqual(wechat_antirecall_recall_log_record_for_test(
            store.directoryURL.path, revokeXML(newMsgId: "78"), "\"赵六\" 撤回了一条消息", nil, 1_715_563_950), 1)

        let entries = try store.load().entries
        XCTAssertEqual(entries.map(\.newMsgId), ["78", "77"])
        XCTAssertEqual(entries[1].session, "room@chatroom")
        XCTAssertEqual(entries[1].notice, "\"王五\" 撤回了一条消息")
        XCTAssertEqual(entries[1].content, "[图片]")
        XCTAssertEqual(entries[1].createTime, 1_715_563_800)
        XCTAssertEqual(entries[1].loggedAt, 1_715_563_900)
        XCTAssertNil(entries[0].content)
    }

    func testUnreadableLogExplainsHowToGrantDiskAccess() throws {
        let store = RecallLogFileStore(homeDirectory: try makeFolder(), domain: "com.tencent.xinWeChat")
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try (fixtureLine("1", loggedAt: 1) + "\n").write(to: store.currentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.currentURL.path)
        try XCTSkipIf(geteuid() == 0, "root ignores file permissions")
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("完全磁盘访问"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("权限"), "the GUI keys its hint on this word")
        }
    }
}

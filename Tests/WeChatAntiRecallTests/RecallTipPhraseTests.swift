import XCTest
@testable import WeChatAntiRecall

final class RecallTipPhraseTests: XCTestCase {
    func testPreviewUsesFixedPrefixAndReplacesSenderPlaceholder() throws {
        let phrase = try RecallTipPhrase("已拦截 {from} 撤回的一条消息")
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let timestamp = calendar.date(from: DateComponents(
            year: 2024,
            month: 1,
            day: 15,
            hour: 17,
            minute: 46,
            second: 44
        ))!

        let preview = RecallTipPreview(
            phrase: phrase,
            senderName: "张三",
            messageKind: "文本消息",
            messageText: "这是一条示例消息",
            timestamp: timestamp,
            timeZone: timeZone
        ).render()

        XCTAssertEqual(
            preview,
            """
            [WeChat Anti-Recall] 已拦截 张三 撤回的一条消息
            [文本消息]这是一条示例消息
            2024-01-15 17:46:44
            """
        )
    }

    func testRejectsEmptyCustomPhrase() {
        XCTAssertThrowsError(try RecallTipPhrase("   ")) { error in
            XCTAssertEqual(error.localizedDescription, "撤回提示短语不能为空")
        }
    }

    func testRejectsCDATAEndMarker() {
        XCTAssertThrowsError(try RecallTipPhrase("拦截到 ]] 撤回 ]]>")) { error in
            XCTAssertEqual(error.localizedDescription, "撤回提示短语不能包含 CDATA 结束标记")
        }
    }

    func testParsesSetCommand() throws {
        let options = try RecallTipPhraseOptions(["set", "已拦截 {from} 撤回"])

        XCTAssertEqual(options.action, .set(try RecallTipPhrase("已拦截 {from} 撤回")))
    }

    func testParsesPreviewCommandWithSender() throws {
        let options = try RecallTipPhraseOptions([
            "preview",
            "已拦截 {from} 于 {time} 撤回",
            "--from",
            "张三",
            "--type",
            "文本消息",
            "--message",
            "这是一条示例消息"
        ])

        XCTAssertEqual(
            options.action,
            .preview(
                phrase: try RecallTipPhrase("已拦截 {from} 于 {time} 撤回"),
                senderName: "张三",
                messageKind: "文本消息",
                messageText: "这是一条示例消息"
            )
        )
    }

    func testParsesProbeCommands() throws {
        XCTAssertEqual(try RecallTipPhraseOptions(["probe", "get"]).action, .probe(.get))
        XCTAssertEqual(try RecallTipPhraseOptions(["probe", "on"]).action, .probe(.set(true)))
        XCTAssertEqual(try RecallTipPhraseOptions(["probe", "off"]).action, .probe(.set(false)))
    }

    func testRuntimeTipInstallOptionSelectsRecallTipPatch() throws {
        let options = try InstallOptions(["--runtime-tip"])

        XCTAssertTrue(options.runtimeTip)
        XCTAssertTrue(options.withTip)
    }

    func testRuntimeDylibOptionEnablesRuntimeTip() throws {
        let options = try InstallOptions(["--runtime-dylib", "/tmp/libWeChatAntiRecallRuntime.dylib"])

        XCTAssertTrue(options.runtimeTip)
        XCTAssertTrue(options.withTip)
        XCTAssertEqual(options.runtimeDylibPath, "/tmp/libWeChatAntiRecallRuntime.dylib")
    }

    func testUpdateOnlyRejectsRuntimeTip() {
        XCTAssertThrowsError(try InstallOptions(["--update-only", "--runtime-tip"])) { error in
            XCTAssertEqual(error.localizedDescription, "--update-only 不能与 --runtime-tip 同时使用")
        }
    }

    func testPreferenceStoreWritesWechatContainerPlist() throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: homeDirectory)
        }

        let store = RecallTipPreferenceStore(homeDirectory: homeDirectory)
        let phrase = try RecallTipPhrase("已拦截 {from} 撤回")

        try store.save(phrase)

        XCTAssertEqual(try store.load(), phrase)

        let data = try Data(contentsOf: store.preferenceFileURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist[RecallTipPreferenceStore.key] as? String, phrase.text)

        try store.reset()

        let resetData = try Data(contentsOf: store.preferenceFileURL)
        let resetPlist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: resetData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertNil(resetPlist[RecallTipPreferenceStore.key])
    }

    func testPreferenceStoreWritesProbeFlag() throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: homeDirectory)
        }

        let store = RecallTipPreferenceStore(homeDirectory: homeDirectory)

        XCTAssertFalse(try store.isProbeEnabled())

        try store.setProbeEnabled(true)
        XCTAssertTrue(try store.isProbeEnabled())

        let data = try Data(contentsOf: store.preferenceFileURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist[RecallTipPreferenceStore.probeKey] as? Bool, true)

        try store.setProbeEnabled(false)
        XCTAssertFalse(try store.isProbeEnabled())
    }

    func testPreferenceResetDoesNotCreateMissingPlist() throws {
        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: homeDirectory)
        }

        let store = RecallTipPreferenceStore(homeDirectory: homeDirectory)

        try store.reset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.preferenceFileURL.path))
    }
}

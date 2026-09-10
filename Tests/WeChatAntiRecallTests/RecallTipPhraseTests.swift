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

    func testPreviewSubstitutesContentWithTextForTextMessages() throws {
        let phrase = try RecallTipPhrase("已拦截 {from} 撤回：{content}")
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let timestamp = calendar.date(from: DateComponents(
            year: 2024, month: 1, day: 15, hour: 17, minute: 46, second: 44
        ))!

        let preview = RecallTipPreview(
            phrase: phrase,
            senderName: "张三",
            messageKind: "文本消息",
            messageText: "你好世界",
            timestamp: timestamp,
            timeZone: timeZone
        ).render()

        XCTAssertEqual(
            preview,
            """
            [WeChat Anti-Recall] 已拦截 张三 撤回：你好世界
            [文本消息]你好世界
            2024-01-15 17:46:44
            """
        )
    }

    func testPreviewSubstitutesContentWithPlaceholderForMediaMessages() throws {
        let phrase = try RecallTipPhrase("已拦截 {from} 撤回：{content}")
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let timestamp = calendar.date(from: DateComponents(
            year: 2024, month: 1, day: 15, hour: 17, minute: 46, second: 44
        ))!

        let preview = RecallTipPreview(
            phrase: phrase,
            senderName: "张三",
            messageKind: "图片",
            messageText: "ignored.png",
            timestamp: timestamp,
            timeZone: timeZone
        ).render()

        XCTAssertTrue(preview.contains("已拦截 张三 撤回：[图片]"), preview)
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

    func testParsesAppBeforeAndAfterTargetedCommands() throws {
        let path = "/Applications/WeChat Beta.app"

        let get = try RecallTipPhraseOptions(["--app", path, "get"])
        XCTAssertEqual(get.action, .get)
        XCTAssertEqual(get.appPath, path)

        let set = try RecallTipPhraseOptions(["set", "alternate phrase", "--app", path])
        XCTAssertEqual(set.action, .set(try RecallTipPhrase("alternate phrase")))
        XCTAssertEqual(set.appPath, path)

        let probe = try RecallTipPhraseOptions(["probe", "on", "--app", path])
        XCTAssertEqual(probe.action, .probe(.set(true)))
        XCTAssertEqual(probe.appPath, path)
    }

    func testTipPhraseAppArgumentValidation() {
        XCTAssertThrowsError(try RecallTipPhraseOptions(["get", "--app"])) { error in
            XCTAssertEqual(error.localizedDescription, "--app 需要一个值")
        }
        XCTAssertThrowsError(try RecallTipPhraseOptions([
            "--app", "/Applications/WeChat.app",
            "get",
            "--app", "/Applications/Other.app",
        ])) { error in
            XCTAssertEqual(error.localizedDescription, "tip-phrase --app 只能指定一次")
        }
        XCTAssertThrowsError(try RecallTipPhraseOptions([
            "preview", "示例", "--app", "/Applications/WeChat.app",
        ])) { error in
            XCTAssertEqual(error.localizedDescription, "tip-phrase preview 不接受 --app；预览与目标 App 无关")
        }
        XCTAssertThrowsError(try RecallTipPhraseOptions(["get", "--domain", "com.tencent.xin"])) { error in
            XCTAssertEqual(error.localizedDescription, "tip-phrase get 不接受额外参数")
        }
    }

    func testAlternateOfficialAppDerivesItsPreferenceDomain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-domain-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeWechatApp(in: directory, bundleIdentifier: "com.tencent.xin")

        let domain = try recallTipPreferenceDomain(appPath: appURL.path)

        XCTAssertEqual(domain, "com.tencent.xin")
        let store = RecallTipPreferenceStore(homeDirectory: directory, domain: domain)
        XCTAssertTrue(store.preferenceFileURL.path.contains("Library/Containers/com.tencent.xin/"))
        XCTAssertEqual(try recallTipPreferenceDomain(appPath: nil), RecallTipPreferenceStore.domain)
    }

    func testPreferenceDomainRejectsPathTraversalFromMarkedClone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-domain-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let appURL = try makeWechatApp(
            in: directory,
            bundleIdentifier: "com.tencent.xinWeChat.antirecall.clone1/../../escape",
            cloneMarker: true)

        XCTAssertThrowsError(try recallTipPreferenceDomain(appPath: appURL.path))
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
        let homeDirectory = makePreferenceTestHomeDirectory()
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

    func testPreferenceStoreCanWriteCloneBundleDomain() throws {
        let homeDirectory = makePreferenceTestHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeDirectory)
        }

        let store = RecallTipPreferenceStore(
            homeDirectory: homeDirectory,
            domain: "com.tencent.xinWeChat.antirecall.clone1"
        )
        let phrase = try RecallTipPhrase("clone 1 phrase")

        try store.save(phrase)

        XCTAssertEqual(try store.load(), phrase)
        XCTAssertEqual(
            store.preferenceFileURL.path,
            homeDirectory
                .appendingPathComponent("Library/Containers/com.tencent.xinWeChat.antirecall.clone1/Data/Library/Preferences")
                .appendingPathComponent("com.tencent.xinWeChat.antirecall.clone1.plist")
                .path
        )
    }

    func testPreferenceStoreWritesProbeFlag() throws {
        let homeDirectory = makePreferenceTestHomeDirectory()
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

    func testPreferenceStoreMutationsAreVisibleThroughPreferencesDaemon() throws {
        let homeDirectory = makePreferenceTestHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeDirectory)
        }

        let store = RecallTipPreferenceStore(homeDirectory: homeDirectory)
        let domainPath = store.preferenceFileURL.deletingPathExtension().path
        let phrase = try RecallTipPhrase("已拦截 {from} 撤回：{content}")

        // Prime cfprefsd with a stale domain before the store mutates it. A direct
        // PropertyListSerialization write is not visible here and is later overwritten.
        try runDefaults(["write", domainPath, "ExistingSetting", "-string", "preserved"])
        try store.save(phrase)
        try store.setProbeEnabled(true)

        var exported = try exportedDefaultsDomain(domainPath)
        XCTAssertEqual(exported["ExistingSetting"] as? String, "preserved")
        XCTAssertEqual(exported[RecallTipPreferenceStore.key] as? String, phrase.text)
        XCTAssertEqual(exported[RecallTipPreferenceStore.probeKey] as? Bool, true)

        try store.reset()
        exported = try exportedDefaultsDomain(domainPath)
        XCTAssertNil(exported[RecallTipPreferenceStore.key])
        XCTAssertEqual(exported[RecallTipPreferenceStore.probeKey] as? Bool, true)
    }

    func testPreferenceResetDoesNotCreateMissingPlist() throws {
        let homeDirectory = makePreferenceTestHomeDirectory()
        defer {
            try? FileManager.default.removeItem(at: homeDirectory)
        }

        let store = RecallTipPreferenceStore(homeDirectory: homeDirectory)

        try store.reset()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.preferenceFileURL.path))
    }
    private func makeWechatApp(
        in directory: URL,
        bundleIdentifier: String,
        cloneMarker: Bool = false
    ) throws -> URL {
        let appURL = directory.appendingPathComponent("WeChat.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleExecutable": "WeChat",
            "CFBundleShortVersionString": "4.1.13",
            "CFBundleVersion": "269624",
            "CFBundleIdentifier": bundleIdentifier,
        ]
        if cloneMarker {
            plist[WeChatCloneMetadata.markerKey] = true
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    private func runDefaults(_ arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "RecallTipPhraseTests.defaults",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "defaults failed"]
            )
        }
    }

    private func makePreferenceTestHomeDirectory() -> URL {
        // `defaults` rejects arbitrary preference domains below macOS's per-user
        // /var/folders temporary root. /private/tmp exercises the same absolute-path
        // domain behavior used in production without that test-only restriction.
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("wechat-antirecall-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func exportedDefaultsDomain(_ domainPath: String) throws -> [String: Any] {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["export", domainPath, "-"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "RecallTipPhraseTests.defaults",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "defaults export failed"]
            )
        }
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }

}

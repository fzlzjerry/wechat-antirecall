import XCTest
@testable import WeChatAntiRecall

final class CloneTests: XCTestCase {
    func testCloneOptionsUseSafeDefaults() throws {
        let options = try CloneOptions([])

        XCTAssertEqual(options.appPath, "/Applications/WeChat.app")
        XCTAssertEqual(options.outputDir, "/Applications")
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.namePrefix, "WeChat")
        XCTAssertFalse(options.dryRun)
        XCTAssertFalse(options.replace)
        XCTAssertFalse(options.keepURLSchemes)
        XCTAssertFalse(options.skipResign)
    }

    func testCloneOptionsParseExplicitValues() throws {
        let options = try CloneOptions([
            "--app", "/tmp/WeChat.app",
            "--output-dir", "/tmp",
            "--count", "3",
            "--name-prefix", "WeChat Test",
            "--dry-run",
            "--replace",
            "--keep-url-schemes",
            "--skip-resign"
        ])

        XCTAssertEqual(options.appPath, "/tmp/WeChat.app")
        XCTAssertEqual(options.outputDir, "/tmp")
        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options.namePrefix, "WeChat Test")
        XCTAssertTrue(options.dryRun)
        XCTAssertTrue(options.replace)
        XCTAssertTrue(options.keepURLSchemes)
        XCTAssertTrue(options.skipResign)
    }

    func testPlannerBuildsStableCloneNamesAndBundleIdentifiers() throws {
        let sourceURL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
        let appInfo = AppInfo(
            appURL: sourceURL,
            executableURL: sourceURL.appendingPathComponent("Contents/MacOS/WeChat"),
            shortVersion: "4.1.9",
            buildVersion: "268602",
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        let options = try CloneOptions(["--count", "2", "--output-dir", "/Applications"])

        let specs = try WeChatClonePlanner().plan(appInfo: appInfo, options: options)

        XCTAssertEqual(specs.map(\.displayName), ["WeChat 1", "WeChat 2"])
        XCTAssertEqual(specs.map(\.bundleIdentifier), [
            "com.tencent.xinWeChat.antirecall.clone1",
            "com.tencent.xinWeChat.antirecall.clone2"
        ])
        XCTAssertEqual(specs.map { $0.destinationURL.path }, [
            "/Applications/WeChat 1.app",
            "/Applications/WeChat 2.app"
        ])
    }

    func testPlannerRejectsOutputDirectoryInsideSourceBundle() throws {
        let sourceURL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)
        let appInfo = AppInfo(
            appURL: sourceURL,
            executableURL: sourceURL.appendingPathComponent("Contents/MacOS/WeChat"),
            shortVersion: "4.1.9",
            buildVersion: "268602",
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        let options = try CloneOptions(["--output-dir", "/Applications/WeChat.app/Contents"])

        XCTAssertThrowsError(try WeChatClonePlanner().plan(appInfo: appInfo, options: options)) { error in
            XCTAssertEqual(error.localizedDescription, "clone 输出目录不能位于源 App bundle 内")
        }
    }

    func testPlannerRejectsDestinationEqualToSourceBundle() throws {
        let sourceURL = URL(fileURLWithPath: "/Applications/WeChat 1.app", isDirectory: true)
        let appInfo = AppInfo(
            appURL: sourceURL,
            executableURL: sourceURL.appendingPathComponent("Contents/MacOS/WeChat"),
            shortVersion: "4.1.9",
            buildVersion: "268602",
            bundleIdentifier: "com.tencent.xinWeChat.antirecall.clone1"
        )
        let options = try CloneOptions(["--output-dir", "/Applications", "--count", "1"])

        XCTAssertThrowsError(try WeChatClonePlanner().plan(appInfo: appInfo, options: options)) { error in
            XCTAssertEqual(error.localizedDescription, "clone 目标不能等于源 App bundle")
        }
    }

    func testPlistEditorRemovesURLSchemesByDefaultAndWritesCloneMarker() throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.tencent.xinWeChat",
            "CFBundleName": "WeChat",
            "CFBundleDisplayName": "WeChat",
            "CFBundleGetInfoString": "WeChat",
            "CFBundleURLTypes": [
                [
                    "CFBundleURLName": "com.tencent.xinWeChat",
                    "CFBundleURLSchemes": ["xweixin", "weixin", "wechat"]
                ]
            ]
        ]
        let spec = WeChatCloneSpec(
            index: 1,
            displayName: "WeChat 1",
            bundleIdentifier: "com.tencent.xinWeChat.antirecall.clone1",
            sourceURL: URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true),
            destinationURL: URL(fileURLWithPath: "/Applications/WeChat 1.app", isDirectory: true)
        )

        let edited = WeChatClonePlistEditor().editedPlist(plist, spec: spec, keepURLSchemes: false)

        XCTAssertEqual(edited["CFBundleIdentifier"] as? String, "com.tencent.xinWeChat.antirecall.clone1")
        XCTAssertEqual(edited["CFBundleName"] as? String, "WeChat 1")
        XCTAssertEqual(edited["CFBundleDisplayName"] as? String, "WeChat 1")
        XCTAssertEqual(edited["CFBundleGetInfoString"] as? String, "WeChat 1")
        XCTAssertNil(edited["CFBundleURLTypes"])
        XCTAssertEqual(edited["WeChatAntiRecallClone"] as? Bool, true)
        XCTAssertEqual(edited["WeChatAntiRecallCloneIndex"] as? Int, 1)
        XCTAssertEqual(edited["WeChatAntiRecallCloneSourceBundleIdentifier"] as? String, "com.tencent.xinWeChat")
    }

    func testPlistEditorKeepsURLSchemesWhenRequested() throws {
        let urlTypes = [
            [
                "CFBundleURLName": "com.tencent.xinWeChat",
                "CFBundleURLSchemes": ["xweixin", "weixin", "wechat"]
            ]
        ]
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.tencent.xinWeChat",
            "CFBundleName": "WeChat",
            "CFBundleURLTypes": urlTypes
        ]
        let spec = WeChatCloneSpec(
            index: 1,
            displayName: "WeChat 1",
            bundleIdentifier: "com.tencent.xinWeChat.antirecall.clone1",
            sourceURL: URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true),
            destinationURL: URL(fileURLWithPath: "/Applications/WeChat 1.app", isDirectory: true)
        )

        let edited = WeChatClonePlistEditor().editedPlist(plist, spec: spec, keepURLSchemes: true)

        XCTAssertNotNil(edited["CFBundleURLTypes"])
    }

    func testDryRunDoesNotCreateCloneApp() throws {
        let fixture = try makeFakeWechatApp()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let outputDir = fixture.root.appendingPathComponent("Output", isDirectory: true)
        let options = try CloneOptions([
            "--app", fixture.appURL.path,
            "--output-dir", outputDir.path,
            "--dry-run"
        ])

        let specs = try WeChatCloneInstaller().install(appInfo: fixture.appInfo, options: options)

        XCTAssertEqual(specs.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("WeChat 1.app").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("WeChat 2.app").path))
    }

    func testInstallerCopiesCloneWithoutChangingSourcePlist() throws {
        let fixture = try makeFakeWechatApp()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let outputDir = fixture.root.appendingPathComponent("Output", isDirectory: true)
        let options = try CloneOptions([
            "--app", fixture.appURL.path,
            "--output-dir", outputDir.path,
            "--count", "1",
            "--skip-resign"
        ])
        let sourceBefore = try Data(contentsOf: fixture.infoPlistURL)

        let specs = try WeChatCloneInstaller().install(appInfo: fixture.appInfo, options: options)

        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.infoPlistURL), sourceBefore)

        let clonePlistURL = outputDir.appendingPathComponent("WeChat 1.app/Contents/Info.plist")
        let clonePlist = try readPlist(clonePlistURL)
        XCTAssertEqual(clonePlist["CFBundleIdentifier"] as? String, "com.tencent.xinWeChat.antirecall.clone1")
        XCTAssertEqual(clonePlist["CFBundleExecutable"] as? String, "WeChat")
        XCTAssertNil(clonePlist["CFBundleURLTypes"])
    }

    func testInstallerRejectsExistingCloneWithoutReplace() throws {
        let fixture = try makeFakeWechatApp()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let outputDir = fixture.root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir.appendingPathComponent("WeChat 1.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        let options = try CloneOptions([
            "--app", fixture.appURL.path,
            "--output-dir", outputDir.path,
            "--count", "1",
            "--skip-resign"
        ])

        XCTAssertThrowsError(try WeChatCloneInstaller().install(appInfo: fixture.appInfo, options: options)) { error in
            XCTAssertEqual(error.localizedDescription, "目标 clone 已存在：\(outputDir.path)/WeChat 1.app。请先移走它，或显式使用 --replace")
        }
    }

    private func makeFakeWechatApp() throws -> (
        root: URL,
        appURL: URL,
        infoPlistURL: URL,
        appInfo: AppInfo
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-clone-tests-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try Data([0xca, 0xfe]).write(to: macOSURL.appendingPathComponent("WeChat"))
        try Data([0xba, 0xbe]).write(to: resourcesURL.appendingPathComponent("wechat.dylib"))

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let plist: [String: Any] = [
            "CFBundleExecutable": "WeChat",
            "CFBundleIdentifier": "com.tencent.xinWeChat",
            "CFBundleName": "WeChat",
            "CFBundleDisplayName": "WeChat",
            "CFBundleGetInfoString": "WeChat",
            "CFBundleShortVersionString": "4.1.9",
            "CFBundleVersion": "268602",
            "CFBundleURLTypes": [
                [
                    "CFBundleURLName": "com.tencent.xinWeChat",
                    "CFBundleURLSchemes": ["xweixin", "weixin", "wechat"]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: infoPlistURL)

        return (
            root,
            appURL,
            infoPlistURL,
            AppInfo(
                appURL: appURL,
                executableURL: macOSURL.appendingPathComponent("WeChat"),
                shortVersion: "4.1.9",
                buildVersion: "268602",
                bundleIdentifier: "com.tencent.xinWeChat"
            )
        )
    }

    private func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        )
    }
}

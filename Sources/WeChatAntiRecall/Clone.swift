import Foundation

struct CloneOptions {
    var appPath = "/Applications/WeChat.app"
    var outputDir = "/Applications"
    var count = 2
    var namePrefix = "WeChat"
    var dryRun = false
    var replace = false
    var keepURLSchemes = false
    var skipResign = false
    var json = false

    init(_ arguments: [String]) throws {
        var parser = ArgumentCursor(arguments)
        while let argument = parser.next() {
            switch argument {
            case "--app":
                appPath = try parser.requiredValue(after: argument)
            case "--output-dir":
                outputDir = try parser.requiredValue(after: argument)
            case "--count":
                let value = try parser.requiredValue(after: argument)
                guard let parsed = Int(value), parsed > 0 else {
                    throw ToolError.usage("--count 必须是大于 0 的整数")
                }
                count = parsed
            case "--name-prefix":
                let value = try parser.requiredValue(after: argument)
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ToolError.usage("--name-prefix 不能为空")
                }
                namePrefix = value
            case "--dry-run":
                dryRun = true
            case "--replace":
                replace = true
            case "--keep-url-schemes":
                keepURLSchemes = true
            case "--skip-resign":
                skipResign = true
            case "--json":
                json = true
            default:
                throw ToolError.usage("未知参数：\(argument)")
            }
        }
    }
}

struct WeChatCloneSpec {
    let index: Int
    let displayName: String
    let bundleIdentifier: String
    let sourceURL: URL
    let destinationURL: URL
}

enum WeChatCloneMetadata {
    static let markerKey = "WeChatAntiRecallClone"
    static let cloneIndexKey = "WeChatAntiRecallCloneIndex"
    static let sourceBundleIdentifierKey = "WeChatAntiRecallCloneSourceBundleIdentifier"
    static let bundleIdentifierPrefix = "com.tencent.xinWeChat.antirecall.clone"

    static func bundleIdentifier(for index: Int) -> String {
        "\(bundleIdentifierPrefix)\(index)"
    }

    static func isAcceptedClone(plist: [String: Any], bundleIdentifier: String) -> Bool {
        guard bundleIdentifier.hasPrefix(bundleIdentifierPrefix) else {
            return false
        }
        return plist[markerKey] as? Bool == true
    }
}

struct WeChatClonePlanner {
    func plan(appInfo: AppInfo, options: CloneOptions) throws -> [WeChatCloneSpec] {
        let sourceURL = appInfo.appURL.standardizedFileURL
        let outputURL = URL(fileURLWithPath: options.outputDir, isDirectory: true).standardizedFileURL
        let sourcePath = sourceURL.path
        let outputPath = outputURL.path
        if outputPath == sourcePath || outputPath.hasPrefix(sourcePath + "/") {
            throw ToolError.usage("clone 输出目录不能位于源 App bundle 内")
        }

        return try (1...options.count).map { index in
            let displayName = "\(options.namePrefix) \(index)"
            let destinationURL = outputURL.appendingPathComponent("\(displayName).app", isDirectory: true).standardizedFileURL
            let destinationPath = destinationURL.path
            if destinationPath == sourcePath {
                throw ToolError.usage("clone 目标不能等于源 App bundle")
            }
            if destinationPath.hasPrefix(sourcePath + "/") {
                throw ToolError.usage("clone 目标不能位于源 App bundle 内")
            }
            return WeChatCloneSpec(
                index: index,
                displayName: displayName,
                bundleIdentifier: WeChatCloneMetadata.bundleIdentifier(for: index),
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        }
    }
}

struct WeChatClonePlistEditor {
    func editedPlist(_ plist: [String: Any], spec: WeChatCloneSpec, keepURLSchemes: Bool) -> [String: Any] {
        var edited = plist
        let sourceBundleIdentifier = plist["CFBundleIdentifier"] as? String ?? ""
        edited["CFBundleIdentifier"] = spec.bundleIdentifier
        edited["CFBundleName"] = spec.displayName
        edited["CFBundleDisplayName"] = spec.displayName
        edited["CFBundleGetInfoString"] = spec.displayName
        edited[WeChatCloneMetadata.markerKey] = true
        edited[WeChatCloneMetadata.cloneIndexKey] = spec.index
        edited[WeChatCloneMetadata.sourceBundleIdentifierKey] = sourceBundleIdentifier

        if !keepURLSchemes {
            edited.removeValue(forKey: "CFBundleURLTypes")
        }

        return edited
    }
}

struct WeChatCloneInstaller {
    private let planner = WeChatClonePlanner()
    private let plistEditor = WeChatClonePlistEditor()

    func install(appInfo: AppInfo, options: CloneOptions) throws -> [WeChatCloneSpec] {
        let specs = try planner.plan(appInfo: appInfo, options: options)
        guard !options.dryRun else {
            return specs
        }

        let fileManager = FileManager.default
        let outputURL = URL(fileURLWithPath: options.outputDir, isDirectory: true)
        do {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            throw ToolError.fileOperationFailed(
                operation: "创建 clone 输出目录",
                path: outputURL.path,
                underlying: error.localizedDescription
            )
        }

        for spec in specs {
            try install(spec: spec, keepURLSchemes: options.keepURLSchemes, replace: options.replace, skipResign: options.skipResign)
        }

        return specs
    }

    private func install(
        spec: WeChatCloneSpec,
        keepURLSchemes: Bool,
        replace: Bool,
        skipResign: Bool
    ) throws {
        let fileManager = FileManager.default
        let destinationURL = spec.destinationURL
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(spec.displayName).wechat-antirecall-\(UUID().uuidString).app", isDirectory: true)

        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        if fileManager.fileExists(atPath: destinationURL.path), !replace {
            throw ToolError.usage("目标 clone 已存在：\(destinationURL.path)。请先移走它，或显式使用 --replace")
        }

        do {
            try fileManager.copyItem(at: spec.sourceURL, to: temporaryURL)
            try rewriteInfoPlist(in: temporaryURL, spec: spec, keepURLSchemes: keepURLSchemes)
            if !skipResign {
                try resign(appURL: temporaryURL, nestedBinaries: [])
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                try moveExistingCloneAside(destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.fileOperationFailed(
                operation: "创建 clone",
                path: destinationURL.path,
                underlying: error.localizedDescription
            )
        }
    }

    private func rewriteInfoPlist(in appURL: URL, spec: WeChatCloneSpec, keepURLSchemes: Bool) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        var plistFormat = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [.mutableContainersAndLeaves],
            format: &plistFormat
        ) as? [String: Any] else {
            throw ToolError.notAWechatApp(appURL.path)
        }

        let edited = plistEditor.editedPlist(plist, spec: spec, keepURLSchemes: keepURLSchemes)
        let data = try PropertyListSerialization.data(
            fromPropertyList: edited,
            format: plistFormat,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private func moveExistingCloneAside(_ destinationURL: URL) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: Date())
        let backupURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(destinationURL.lastPathComponent).wechat-antirecall-backup-\(suffix)", isDirectory: true)
        try FileManager.default.moveItem(at: destinationURL, to: backupURL)
    }
}

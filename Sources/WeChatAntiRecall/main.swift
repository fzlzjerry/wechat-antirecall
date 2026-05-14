import Foundation
import Darwin

private let defaultAppPath = "/Applications/WeChat.app"
private let defaultBinaryPath = "Contents/MacOS/WeChat"
private let lcSegment64: UInt32 = 0x19
private let lcLoadDylib: UInt32 = 0xc
private let mhMagic64: UInt32 = 0xfeedfacf
private let mhDylib: UInt32 = 0x6
private let fatMagic: UInt32 = 0xcafebabe
private let fatMagic64: UInt32 = 0xcafebabf
private let cpuTypeX8664: Int32 = 0x01000007
private let cpuTypeARM64: Int32 = 0x0100000c
private let codesignPreservedMetadata = "entitlements,requirements,flags,runtime"

enum ToolError: LocalizedError {
    case usage(String)
    case unsupportedVersion(found: String, supported: [String])
    case invalidConfig(String)
    case invalidHex(String)
    case appInfoMissing(String)
    case notAWechatApp(String)
    case unsupportedMachO(String)
    case addressNotMapped(address: UInt64, file: String)
    case bytesMismatch(address: UInt64, expected: [Data], actual: Data)
    case noMatchingSlice(String)
    case commandFailed(String, Int32)
    case permissionDenied(path: String, operation: String)
    case fileOperationFailed(operation: String, path: String, underlying: String)
    case appIsRunning(path: String, pids: [String])
    case invalidBundleRelativePath(String)
    case invalidRuntimeDylib(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .unsupportedVersion(let found, let supported):
            return "当前微信构建号 \(found) 不在补丁配置中。已支持构建号：\(supported.joined(separator: ", "))"
        case .invalidConfig(let message):
            return "补丁配置无效：\(message)"
        case .invalidHex(let value):
            return "十六进制字符串无效：\(value)"
        case .appInfoMissing(let key):
            return "无法从 Info.plist 读取 \(key)"
        case .notAWechatApp(let path):
            return "\(path) 看起来不是 macOS 微信应用"
        case .unsupportedMachO(let path):
            return "不支持的 Mach-O 文件：\(path)"
        case .addressNotMapped(let address, let file):
            return "地址 0x\(String(address, radix: 16)) 无法映射到文件 \(file)"
        case .bytesMismatch(let address, let expected, let actual):
            let expectedText = expected.map(\.hexString).joined(separator: " 或 ")
            return "地址 0x\(String(address, radix: 16)) 原始字节不匹配，期望 \(expectedText)，实际 \(actual.hexString)"
        case .noMatchingSlice(let path):
            return "\(path) 中没有找到配置要求的架构切片"
        case .commandFailed(let command, let status):
            return "\(command) 执行失败，退出码 \(status)"
        case .permissionDenied(let path, let operation):
            return """
            没有权限\(operation)：\(path)
            当前有效用户 ID：\(geteuid())。安装到 /Applications/WeChat.app 通常需要管理员权限。请先构建 release 版本，再用 sudo 运行安装或恢复命令，例如：
              swift build -c release
              sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app
            """
        case .fileOperationFailed(let operation, let path, let underlying):
            return """
            \(operation)失败：\(path)
            底层错误：\(underlying)
            当前有效用户 ID：\(geteuid())。如果已经通过 sudo 运行但底层错误是 Operation not permitted，请在 macOS 系统设置的 Privacy & Security 中给当前终端应用开启 App Management，必要时同时开启 Full Disk Access，然后退出并重新打开终端再试。
            """
        case .appIsRunning(let path, let pids):
            return """
            WeChat 仍在运行，不能在运行中修改或恢复 app bundle：\(path)
            正在运行的进程 PID：\(pids.joined(separator: ", "))
            请先完全退出微信，再重新运行命令。运行中修改二进制可能触发 macOS Code Signature Invalid 崩溃。
            """
        case .invalidBundleRelativePath(let path):
            return "app bundle 内相对路径无效：\(path)"
        case .invalidRuntimeDylib(let path, let reason):
            return "runtime dylib 无效：\(path)。\(reason)"
        }
    }
}

enum CPUArch: String, Decodable, Hashable {
    case arm64
    case x86_64

    var cpuType: Int32 {
        switch self {
        case .arm64:
            return cpuTypeARM64
        case .x86_64:
            return cpuTypeX8664
        }
    }
}

struct PatchEntry: Decodable, Hashable {
    let arch: CPUArch
    let address: UInt64
    let patchBytes: Data
    let expectedBytes: [Data]

    enum CodingKeys: String, CodingKey {
        case arch
        case address = "addr"
        case patchBytes = "asm"
        case expectedBytes = "expected"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        arch = try container.decode(CPUArch.self, forKey: .arch)

        let addressString = try container.decode(String.self, forKey: .address)
        guard let parsedAddress = UInt64(addressString, radix: 16) else {
            throw ToolError.invalidHex(addressString)
        }
        address = parsedAddress

        let patchString = try container.decode(String.self, forKey: .patchBytes)
        patchBytes = try Data(hexString: patchString)

        if container.contains(.expectedBytes) {
            if let expectedString = try? container.decode(String.self, forKey: .expectedBytes) {
                expectedBytes = [try Data(hexString: expectedString)]
            } else if let expectedStrings = try? container.decode([String].self, forKey: .expectedBytes) {
                expectedBytes = try expectedStrings.map { try Data(hexString: $0) }
            } else {
                throw ToolError.invalidConfig("addr \(addressString) 的 expected 必须是字符串或字符串数组")
            }
        } else {
            expectedBytes = []
        }
    }
}

struct PatchTarget: Decodable {
    let identifier: String
    let binary: String?
    let entries: [PatchEntry]

    var binaryPath: String {
        binary ?? defaultBinaryPath
    }
}

struct VersionConfig: Decodable {
    let version: String
    let targets: [PatchTarget]
}

struct AppInfo {
    let appURL: URL
    let executableURL: URL
    let shortVersion: String
    let buildVersion: String
    let bundleIdentifier: String
}

enum BundleRelativePath {
    static func resolve(_ relativePath: String, in appURL: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath != "." else {
            throw ToolError.invalidBundleRelativePath(relativePath)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ToolError.invalidBundleRelativePath(relativePath)
        }

        let canonicalAppURL = appURL.standardizedFileURL
        let canonicalAppPath = canonicalAppURL.path.hasSuffix("/")
            ? canonicalAppURL.path
            : "\(canonicalAppURL.path)/"
        let resolvedURL = canonicalAppURL.appendingPathComponent(relativePath).standardizedFileURL

        guard resolvedURL.path.hasPrefix(canonicalAppPath) else {
            throw ToolError.invalidBundleRelativePath(relativePath)
        }

        return resolvedURL
    }
}

enum PatchStatus {
    case patched
    case wouldPatch
    case alreadyPatched
}

struct PatchReport {
    let arch: CPUArch
    let address: UInt64
    let fileOffset: UInt64
    let status: PatchStatus
}

enum DylibInjectionStatus: Equatable {
    case injected
    case wouldInject
    case alreadyInjected
}

struct DylibInjectionReport {
    let arch: CPUArch
    let installName: String
    let commandOffset: UInt64
    let paddingLeft: UInt64
    let status: DylibInjectionStatus
}

struct RecallTipPhrase: Equatable {
    static let defaultText = "已拦截一条撤回消息"
    static let maximumLength = 120

    let text: String

    init(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecallTipPhraseError.empty
        }
        guard !trimmed.contains(where: \.isNewline) else {
            throw RecallTipPhraseError.containsNewline
        }
        guard !trimmed.contains("]]>") else {
            throw RecallTipPhraseError.containsCDATAEndMarker
        }
        guard trimmed.count <= Self.maximumLength else {
            throw RecallTipPhraseError.tooLong(maximumLength: Self.maximumLength)
        }

        text = trimmed
    }

    static var `default`: RecallTipPhrase {
        try! RecallTipPhrase(defaultText)
    }

    func rendered(senderName: String?, timestamp: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        return text
            .replacingOccurrences(of: "{from}", with: senderName ?? "")
            .replacingOccurrences(of: "{time}", with: formatter.string(from: timestamp))
    }
}

enum RecallTipPhraseError: LocalizedError, Equatable {
    case empty
    case containsNewline
    case containsCDATAEndMarker
    case tooLong(maximumLength: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "撤回提示短语不能为空"
        case .containsNewline:
            return "撤回提示短语不能包含换行"
        case .containsCDATAEndMarker:
            return "撤回提示短语不能包含 CDATA 结束标记"
        case .tooLong(let maximumLength):
            return "撤回提示短语不能超过 \(maximumLength) 个字符"
        }
    }
}

struct RecallTipPreview {
    static let fixedPrefix = "WeChat Anti-Recall"

    let phrase: RecallTipPhrase
    let senderName: String?
    let messageKind: String
    let messageText: String
    let timestamp: Date
    let timeZone: TimeZone

    func render() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return """
        [\(Self.fixedPrefix)] \(phrase.rendered(senderName: senderName, timestamp: timestamp, timeZone: timeZone))
        [\(messageKind)]\(messageText)
        \(formatter.string(from: timestamp))
        """
    }
}

enum RecallTipPhraseAction: Equatable {
    case get
    case set(RecallTipPhrase)
    case reset
    case preview(phrase: RecallTipPhrase, senderName: String?, messageKind: String, messageText: String)
    case probe(RecallTipProbeAction)
}

enum RecallTipProbeAction: Equatable {
    case get
    case set(Bool)
}

struct RecallTipPhraseOptions {
    let action: RecallTipPhraseAction

    init(_ arguments: [String]) throws {
        var parser = ArgumentCursor(arguments)
        guard let command = parser.next() else {
            throw ToolError.usage("tip-phrase 需要 get、set、reset 或 preview")
        }

        switch command {
        case "get":
            guard parser.next() == nil else {
                throw ToolError.usage("tip-phrase get 不接受额外参数")
            }
            action = .get
        case "set":
            let phrase = try RecallTipPhrase(parser.requiredValue(after: "set"))
            guard parser.next() == nil else {
                throw ToolError.usage("tip-phrase set 只接受一个短语")
            }
            action = .set(phrase)
        case "reset":
            guard parser.next() == nil else {
                throw ToolError.usage("tip-phrase reset 不接受额外参数")
            }
            action = .reset
        case "preview":
            let phrase = try RecallTipPhrase(parser.requiredValue(after: "preview"))
            var senderName: String?
            var messageKind = "文本消息"
            var messageText = "这是一条示例消息"

            while let argument = parser.next() {
                switch argument {
                case "--from":
                    senderName = try parser.requiredValue(after: argument)
                case "--type":
                    messageKind = try parser.requiredValue(after: argument)
                case "--message":
                    messageText = try parser.requiredValue(after: argument)
                default:
                    throw ToolError.usage("未知参数：\(argument)")
                }
            }

            action = .preview(
                phrase: phrase,
                senderName: senderName,
                messageKind: messageKind,
                messageText: messageText
            )
        case "probe":
            guard let probeCommand = parser.next() else {
                throw ToolError.usage("tip-phrase probe 需要 get、on 或 off")
            }
            guard parser.next() == nil else {
                throw ToolError.usage("tip-phrase probe 不接受额外参数")
            }

            switch probeCommand {
            case "get":
                action = .probe(.get)
            case "on":
                action = .probe(.set(true))
            case "off":
                action = .probe(.set(false))
            default:
                throw ToolError.usage("未知 tip-phrase probe 命令：\(probeCommand)")
            }
        default:
            throw ToolError.usage("未知 tip-phrase 命令：\(command)")
        }
    }
}

struct RecallTipPreferenceStore {
    static let domain = "com.tencent.xinWeChat"
    static let key = "WeChatAntiRecall_RevokeTipPhrase"
    static let probeKey = "WeChatAntiRecall_RevokeTipDebugProbe"

    let preferenceFileURL: URL

    init(homeDirectory: URL = RecallTipPreferenceStore.defaultHomeDirectory()) {
        preferenceFileURL = homeDirectory
            .appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences")
            .appendingPathComponent("\(Self.domain).plist")
    }

    func load() throws -> RecallTipPhrase? {
        let preferences = try readPreferences()
        guard let value = preferences[Self.key] as? String else {
            return nil
        }
        return try RecallTipPhrase(value)
    }

    func save(_ phrase: RecallTipPhrase) throws {
        var preferences = try readPreferences()
        preferences[Self.key] = phrase.text
        try writePreferences(preferences)
    }

    func reset() throws {
        guard FileManager.default.fileExists(atPath: preferenceFileURL.path) else {
            return
        }

        var preferences = try readPreferences()
        guard preferences.removeValue(forKey: Self.key) != nil else {
            return
        }
        try writePreferences(preferences)
    }

    func isProbeEnabled() throws -> Bool {
        let preferences = try readPreferences()
        return preferences[Self.probeKey] as? Bool ?? false
    }

    func setProbeEnabled(_ enabled: Bool) throws {
        var preferences = try readPreferences()
        preferences[Self.probeKey] = enabled
        try writePreferences(preferences)
    }

    private func readPreferences() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: preferenceFileURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: preferenceFileURL)
        guard !data.isEmpty else {
            return [:]
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let preferences = try PropertyListSerialization.propertyList(
            from: data,
            options: [.mutableContainersAndLeaves],
            format: &format
        ) as? [String: Any] else {
            throw ToolError.fileOperationFailed(
                operation: "读取撤回提示短语配置",
                path: preferenceFileURL.path,
                underlying: "plist root is not a dictionary"
            )
        }

        return preferences
    }

    private func writePreferences(_ preferences: [String: Any]) throws {
        try FileManager.default.createDirectory(
            at: preferenceFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try PropertyListSerialization.data(
            fromPropertyList: preferences,
            format: .binary,
            options: 0
        )
        try data.write(to: preferenceFileURL, options: .atomic)
    }

    private static func defaultHomeDirectory() -> URL {
        if geteuid() == 0,
           let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
           sudoUser != "root",
           let passwd = getpwnam(sudoUser) {
            return URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
    }
}

@main
struct WeChatAntiRecall {
    static func main() {
        do {
            try CLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct CLI {
    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "versions":
            try versions(rest)
        case "install", "patch":
            try install(rest)
        case "restore":
            try restore(rest)
        case "clone", "split":
            try clone(rest)
        case "tip-phrase":
            try tipPhrase(rest)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw ToolError.usage("未知命令：\(command)。运行 `wechat-antirecall help` 查看用法。")
        }
    }

    private func versions(_ arguments: [String]) throws {
        let options = try CommonOptions(arguments)
        let configs = try loadConfigs(path: options.configPath)
        let appInfo = try readAppInfo(appPath: options.appPath)

        print("WeChat: \(appInfo.shortVersion) (\(appInfo.buildVersion))")
        print("Bundle: \(appInfo.bundleIdentifier)")
        print("Executable: \(appInfo.executableURL.path)")
        print("")
        print("Supported patch versions:")

        for config in configs {
            let targets = config.targets
                .map { target in
                    let arches = target.entries.reduce(into: [String]()) { result, entry in
                        let arch = entry.arch.rawValue
                        if !result.contains(arch) {
                            result.append(arch)
                        }
                    }.joined(separator: "/")
                    return "\(target.identifier): \(target.binaryPath) [\(arches)]"
                }
                .joined(separator: ", ")
            print("- \(config.version): \(targets)")
        }

        if configs.contains(where: { $0.version == appInfo.buildVersion }) {
            print("")
            print("Status: current WeChat build is supported.")
        } else {
            print("")
            print("Status: current WeChat build is not supported by patches.json.")
        }
    }

    private func install(_ arguments: [String]) throws {
        let options = try InstallOptions(arguments)
        let configs = try loadConfigs(path: options.configPath)
        let appInfo = try readAppInfo(appPath: options.appPath)
        let config = try configForInstalledApp(appInfo, configs: configs)
        let selectedTargets = try resolveTargets(config: config, options: options)
        let targets = selectedTargets.map(\.target)
        let runtimeInstaller = options.runtimeTip ? try RuntimeTipInstaller(appInfo: appInfo, options: options) : nil
        var patchedBinaries: [URL] = []
        var backedUpBinaryPaths = Set<String>()

        print("WeChat: \(appInfo.shortVersion) (\(appInfo.buildVersion))")
        var modeComponents = selectedTargets.map { displayName(forTargetIdentifier: $0.identifier) }
        if options.runtimeTip {
            modeComponents.append("custom recall tip phrase runtime")
        }
        let modeText = modeComponents.joined(separator: ", ")
        print(options.dryRun ? "Mode: dry-run (\(modeText))" : "Mode: \(modeText)")
        print("Checking whether WeChat is running...")
        try ensureAppNotRunning(appInfo: appInfo, dryRun: options.dryRun)
        print("Checking install permissions...")
        try validateInstallPermissions(appInfo: appInfo, targets: targets, options: options, runtimeInstaller: runtimeInstaller)
        if !options.dryRun {
            print("Checking patch applicability...")
            try preflightInstall(appInfo: appInfo, targets: targets, runtimeInstaller: runtimeInstaller)
        }

        var backupRecords: [BackupRecord] = []
        do {
            try performInstallWrites(
                appInfo: appInfo,
                options: options,
                targets: targets,
                runtimeInstaller: runtimeInstaller,
                patchedBinaries: &patchedBinaries,
                backedUpBinaryPaths: &backedUpBinaryPaths,
                backupRecords: &backupRecords
            )
        } catch {
            printInstallRecoveryHints(appInfo: appInfo, backupRecords: backupRecords)
            throw error
        }
    }

    private func performInstallWrites(
        appInfo: AppInfo,
        options: InstallOptions,
        targets: [PatchTarget],
        runtimeInstaller: RuntimeTipInstaller?,
        patchedBinaries: inout [URL],
        backedUpBinaryPaths: inout Set<String>,
        backupRecords: inout [BackupRecord]
    ) throws {
        if let runtimeInstaller {
            if !options.dryRun && !options.noBackup && backedUpBinaryPaths.insert(runtimeInstaller.hostBinaryURL.standardizedFileURL.path).inserted {
                print("Creating backup for \(RuntimeTipInstaller.hostBinaryPath)...")
                let backupURL = try makeBackup(of: runtimeInstaller.hostBinaryURL)
                backupRecords.append(BackupRecord(binaryPath: RuntimeTipInstaller.hostBinaryPath, backupURL: backupURL))
                print("Backup: \(backupURL.path)")
            }

            print(options.dryRun ? "Checking runtime tip injection..." : "Installing runtime tip support...")
            let reports = try runtimeInstaller.install(dryRun: options.dryRun)
            print("Runtime dylib: \(runtimeInstaller.sourceDylibURL.path) -> \(runtimeInstaller.destinationDylibRelativePath)")
            print("Runtime loader target: \(RuntimeTipInstaller.hostBinaryPath)")
            for report in reports {
                let statusText: String
                switch report.status {
                case .injected:
                    statusText = "injected"
                case .wouldInject:
                    statusText = "would inject"
                case .alreadyInjected:
                    statusText = "already injected"
                }
                print("  - \(report.arch.rawValue) \(report.installName) at file+0x\(String(report.commandOffset, radix: 16)) (\(statusText), padding left: \(report.paddingLeft))")
            }

            if !options.dryRun {
                patchedBinaries.append(runtimeInstaller.hostBinaryURL)
                patchedBinaries.append(runtimeInstaller.destinationDylibURL)
            }
        }

        for target in targets {
            let binaryURL = try BundleRelativePath.resolve(target.binaryPath, in: appInfo.appURL)
            if !FileManager.default.fileExists(atPath: binaryURL.path) {
                throw ToolError.invalidConfig("找不到目标二进制：\(target.binaryPath)")
            }
            patchedBinaries.append(binaryURL)

            if !options.dryRun && !options.noBackup && backedUpBinaryPaths.insert(binaryURL.standardizedFileURL.path).inserted {
                print("Creating backup for \(target.binaryPath)...")
                let backupURL = try makeBackup(of: binaryURL)
                backupRecords.append(BackupRecord(binaryPath: target.binaryPath, backupURL: backupURL))
                print("Backup: \(backupURL.path)")
            }

            let reports = try MachOPatcher(fileURL: binaryURL).patch(entries: target.entries, dryRun: options.dryRun)
            print("Patched target: \(target.binaryPath)")
            for report in reports {
                let statusText: String
                switch report.status {
                case .patched:
                    statusText = "patched"
                case .wouldPatch:
                    statusText = "would patch"
                case .alreadyPatched:
                    statusText = "already patched"
                }
                print("  - \(report.arch.rawValue) 0x\(String(report.address, radix: 16)) -> file+0x\(String(report.fileOffset, radix: 16)) (\(statusText))")
            }
        }

        if options.dryRun {
            print("Dry-run complete. No files were changed.")
            return
        }

        if options.skipResign {
            print("Skipped code signing.")
        } else {
            try resign(appURL: appInfo.appURL, nestedBinaries: patchedBinaries)
            print("Code signing complete.")
        }
    }

    private func tipPhrase(_ arguments: [String]) throws {
        let options = try RecallTipPhraseOptions(arguments)
        let store = RecallTipPreferenceStore()

        switch options.action {
        case .get:
            let phrase = try store.load() ?? .default
            print("Domain: \(RecallTipPreferenceStore.domain)")
            print("Key: \(RecallTipPreferenceStore.key)")
            print("File: \(store.preferenceFileURL.path)")
            print("Phrase: \(phrase.text)")
        case .set(let phrase):
            try store.save(phrase)
            print("Saved recall tip phrase.")
            print("Domain: \(RecallTipPreferenceStore.domain)")
            print("Key: \(RecallTipPreferenceStore.key)")
            print("File: \(store.preferenceFileURL.path)")
            printPreview(phrase: phrase, senderName: "张三", messageKind: "文本消息", messageText: "这是一条示例消息")
        case .reset:
            try store.reset()
            print("Reset recall tip phrase to default.")
            print("File: \(store.preferenceFileURL.path)")
            printPreview(phrase: .default, senderName: "张三", messageKind: "文本消息", messageText: "这是一条示例消息")
        case .preview(let phrase, let senderName, let messageKind, let messageText):
            printPreview(phrase: phrase, senderName: senderName, messageKind: messageKind, messageText: messageText)
        case .probe(let action):
            switch action {
            case .get:
                print("Debug probe: \(try store.isProbeEnabled() ? "enabled" : "disabled")")
                print("File: \(store.preferenceFileURL.path)")
            case .set(let enabled):
                try store.setProbeEnabled(enabled)
                print("Debug probe: \(enabled ? "enabled" : "disabled")")
                print("File: \(store.preferenceFileURL.path)")
                if enabled {
                    print("Warning: probe logs revoke metadata and XML previews to macOS Console. Turn it off after collecting evidence.")
                }
            }
        }
    }

    private func resolveTargets(config: VersionConfig, options: InstallOptions) throws -> [(identifier: String, target: PatchTarget)] {
        var selected: [(identifier: String, target: PatchTarget)] = []

        if options.updateOnly {
            guard let updateTarget = config.targets.first(where: { $0.identifier == "update" }) else {
                throw ToolError.invalidConfig("构建号 \(config.version) 没有 update 目标")
            }
            selected.append(("update", updateTarget))
            return selected
        }

        if options.withTip {
            guard let revokeTipTarget = config.targets.first(where: { $0.identifier == "revoke-tip" }) else {
                throw ToolError.invalidConfig("构建号 \(config.version) 没有 revoke-tip 目标")
            }
            selected.append(("revoke-tip", revokeTipTarget))
        } else if let revokeTarget = config.targets.first(where: { $0.identifier == "revoke" }) {
            selected.append(("revoke", revokeTarget))
        } else {
            throw ToolError.invalidConfig("构建号 \(config.version) 没有 revoke 目标")
        }

        if options.multiInstance {
            guard let multiTarget = config.targets.first(where: { $0.identifier == "multiInstance" }) else {
                throw ToolError.invalidConfig("构建号 \(config.version) 没有 multiInstance 目标")
            }
            selected.append(("multiInstance", multiTarget))

            if let multiExtraTarget = config.targets.first(where: { $0.identifier == "multiInstance-extra" }) {
                selected.append(("multiInstance-extra", multiExtraTarget))
            }
        }

        if options.blockUpdate {
            guard let updateTarget = config.targets.first(where: { $0.identifier == "update" }) else {
                throw ToolError.invalidConfig("构建号 \(config.version) 没有 update 目标")
            }
            selected.append(("update", updateTarget))
        }

        return selected
    }

    private func restore(_ arguments: [String]) throws {
        let options = try RestoreOptions(arguments)
        let appInfo = try readAppInfo(appPath: options.appPath)
        let binaryURL = try BundleRelativePath.resolve(options.binaryPath, in: appInfo.appURL)
        let backupURL = URL(fileURLWithPath: options.backupPath)

        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw ToolError.usage("备份文件不存在：\(backupURL.path)")
        }

        try ensureAppNotRunning(appInfo: appInfo, dryRun: false)
        let data = try Data(contentsOf: backupURL)
        try validateRestorePermissions(appInfo: appInfo, binaryURL: binaryURL, skipResign: options.skipResign)
        try data.write(to: binaryURL, options: .atomic)
        print("Restored \(options.binaryPath) from \(backupURL.path)")

        if options.skipResign {
            print("Skipped code signing.")
        } else {
            try resign(appURL: appInfo.appURL, nestedBinaries: [binaryURL])
            print("Code signing complete.")
        }
    }

    private func clone(_ arguments: [String]) throws {
        let options = try CloneOptions(arguments)
        let sourceAppInfo = try readAppInfo(appPath: options.appPath)
        let outputURL = options.outputURL(for: sourceAppInfo.appURL).standardizedFileURL
        let sourceURL = sourceAppInfo.appURL.standardizedFileURL

        guard sourceURL != outputURL else {
            throw ToolError.usage("clone 输出路径不能与源应用相同")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ToolError.usage("clone 输出路径已存在：\(outputURL.path)")
        }

        print("Source: \(sourceAppInfo.appURL.path)")
        print("Output: \(outputURL.path)")
        print("Clone token: \(options.cloneToken)")
        print("Checking whether source WeChat is running...")
        try ensureAppNotRunning(appInfo: sourceAppInfo, dryRun: false)
        print("Checking clone permissions...")
        try validateClonePermissions(outputURL: outputURL)
        print("Copying WeChat.app...")
        do {
            try FileManager.default.copyItem(at: sourceAppInfo.appURL, to: outputURL)
        } catch {
            throw ToolError.fileOperationFailed(
                operation: "复制 WeChat.app",
                path: outputURL.path,
                underlying: error.localizedDescription
            )
        }

        let changes = try AppCloneRewriter(
            appURL: outputURL,
            sourceMainBundleIdentifier: sourceAppInfo.bundleIdentifier,
            cloneToken: options.cloneToken
        ).rewrite()

        print("Updated bundle identifiers:")
        for change in changes {
            print("  - \(change.relativePlistPath): \(change.oldIdentifier) -> \(change.newIdentifier)")
        }

        if options.skipResign {
            print("Skipped code signing.")
        } else {
            print("Re-signing cloned app...")
            try resign(appURL: outputURL, nestedBinaries: [])
            print("Code signing complete.")
        }

        print("Clone created: \(outputURL.path)")
    }

    private func printUsage() {
        print("""
        wechat-antirecall

        Usage:
          wechat-antirecall versions [--app /Applications/WeChat.app] [--config patches.json]
          wechat-antirecall install  [--app /Applications/WeChat.app] [--config patches.json] [--with-tip] [--runtime-tip] [--runtime-dylib <path>] [--multi-instance] [--block-update] [--update-only] [--dry-run] [--no-backup] [--skip-resign]
          wechat-antirecall restore  --backup <path> [--binary Contents/MacOS/WeChat] [--app /Applications/WeChat.app] [--skip-resign]
          wechat-antirecall clone    [--app /Applications/WeChat.app] [--output /Applications/WeChat 2.app] [--index 2] [--skip-resign]
          wechat-antirecall tip-phrase get
          wechat-antirecall tip-phrase set <phrase>
          wechat-antirecall tip-phrase reset
          wechat-antirecall tip-phrase preview <phrase> [--from <name>] [--type <kind>] [--message <text>]
          wechat-antirecall tip-phrase probe get|on|off

        Notes:
          install only patches versions present in patches.json.
          unknown WeChat builds are refused instead of guessed.
        """)
    }
}

private func printPreview(phrase: RecallTipPhrase, senderName: String?, messageKind: String, messageText: String) {
    let preview = RecallTipPreview(
        phrase: phrase,
        senderName: senderName,
        messageKind: messageKind,
        messageText: messageText,
        timestamp: Date(),
        timeZone: .current
    )
    print("Preview:")
    print(preview.render())
}

struct CommonOptions {
    var appPath = defaultAppPath
    var configPath: String?

    init(_ arguments: [String]) throws {
        var parser = ArgumentCursor(arguments)
        while let argument = parser.next() {
            switch argument {
            case "--app":
                appPath = try parser.requiredValue(after: argument)
            case "--config":
                configPath = try parser.requiredValue(after: argument)
            default:
                throw ToolError.usage("未知参数：\(argument)")
            }
        }
    }
}

struct InstallOptions {
    var appPath = defaultAppPath
    var configPath: String?
    var withTip = false
    var multiInstance = false
    var blockUpdate = false
    var updateOnly = false
    var dryRun = false
    var noBackup = false
    var skipResign = false
    var runtimeTip = false
    var runtimeDylibPath: String?

    var targetIdentifiers: [String] {
        if updateOnly {
            return ["update"]
        }

        var identifiers = [withTip ? "revoke-tip" : "revoke"]
        if runtimeTip {
            identifiers.append("runtime-tip")
        }
        if multiInstance {
            identifiers.append("multiInstance")
        }
        if blockUpdate {
            identifiers.append("update")
        }
        return identifiers
    }

    init(_ arguments: [String]) throws {
        var parser = ArgumentCursor(arguments)
        while let argument = parser.next() {
            switch argument {
            case "--app":
                appPath = try parser.requiredValue(after: argument)
            case "--config":
                configPath = try parser.requiredValue(after: argument)
            case "--with-tip":
                withTip = true
            case "--runtime-tip":
                runtimeTip = true
                withTip = true
            case "--runtime-dylib":
                runtimeDylibPath = try parser.requiredValue(after: argument)
                runtimeTip = true
                withTip = true
            case "--multi-instance":
                multiInstance = true
            case "--block-update":
                blockUpdate = true
            case "--update-only":
                updateOnly = true
                blockUpdate = true
            case "--dry-run":
                dryRun = true
            case "--no-backup":
                noBackup = true
            case "--skip-resign":
                skipResign = true
            default:
                throw ToolError.usage("未知参数：\(argument)")
            }
        }

        if updateOnly && runtimeTip {
            throw ToolError.usage("--update-only 不能与 --runtime-tip 同时使用")
        }
        if updateOnly && multiInstance {
            throw ToolError.usage("--update-only 不能与 --multi-instance 同时使用")
        }
        if updateOnly && withTip {
            throw ToolError.usage("--update-only 不能与 --with-tip 同时使用")
        }
    }
}

private func displayName(forTargetIdentifier identifier: String) -> String {
    switch identifier {
    case "revoke":
        return "patch silent"
    case "revoke-tip":
        return "patch with recall tip"
    case "update":
        return "block automatic update"
    case "multiInstance":
        return "enable multi-instance"
    case "multiInstance-extra":
        return "enable multi-instance (extra)"
    default:
        return identifier
    }
}

struct BackupRecord {
    let binaryPath: String
    let backupURL: URL
}

struct CloneOptions {
    var appPath = defaultAppPath
    var outputPath: String?
    var index = 2
    var skipResign = false

    var cloneToken: String {
        "clone\(index)"
    }

    init(_ arguments: [String]) throws {
        var parser = ArgumentCursor(arguments)
        while let argument = parser.next() {
            switch argument {
            case "--app":
                appPath = try parser.requiredValue(after: argument)
            case "--output":
                outputPath = try parser.requiredValue(after: argument)
            case "--index":
                let value = try parser.requiredValue(after: argument)
                guard let parsed = Int(value), parsed >= 2 else {
                    throw ToolError.usage("--index 需要一个大于等于 2 的整数")
                }
                index = parsed
            case "--skip-resign":
                skipResign = true
            default:
                throw ToolError.usage("未知参数：\(argument)")
            }
        }
    }

    func outputURL(for sourceAppURL: URL) -> URL {
        if let outputPath {
            let url = URL(fileURLWithPath: outputPath)
            return url.pathExtension.lowercased() == "app" ? url : url.appendingPathExtension("app")
        }

        let sourceName = sourceAppURL.deletingPathExtension().lastPathComponent
        return sourceAppURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(sourceName) \(index).app")
    }
}

struct RestoreOptions {
    var appPath = defaultAppPath
    var binaryPath = defaultBinaryPath
    var backupPath = ""
    var skipResign = false

    init(_ arguments: [String]) throws {
        var parsedBackupPath: String?
        var parser = ArgumentCursor(arguments)
        while let argument = parser.next() {
            switch argument {
            case "--app":
                appPath = try parser.requiredValue(after: argument)
            case "--binary":
                binaryPath = try parser.requiredValue(after: argument)
            case "--backup":
                parsedBackupPath = try parser.requiredValue(after: argument)
            case "--skip-resign":
                skipResign = true
            default:
                throw ToolError.usage("未知参数：\(argument)")
            }
        }

        guard let parsedBackupPath else {
            throw ToolError.usage("restore 需要 --backup <path>")
        }

        backupPath = parsedBackupPath
    }
}

struct ArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        guard index < arguments.count else {
            return nil
        }
        let value = arguments[index]
        index += 1
        return value
    }

    mutating func requiredValue(after option: String) throws -> String {
        guard let value = next(), !value.hasPrefix("--") else {
            throw ToolError.usage("\(option) 需要一个值")
        }
        return value
    }
}

final class MachOPatcher {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func patch(entries: [PatchEntry], dryRun: Bool) throws -> [PatchReport] {
        let handle: FileHandle = dryRun
            ? try FileHandle(forReadingFrom: fileURL)
            : try FileHandle(forUpdating: fileURL)
        defer {
            try? handle.close()
        }

        let magicData = try handle.readData(at: 0, length: 4)
        let nativeMagic = magicData.leUInt32(at: 0)
        let bigEndianMagic = magicData.beUInt32(at: 0)

        if bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64 {
            return try patchFat(handle: handle, is64BitFat: bigEndianMagic == fatMagic64, entries: entries, dryRun: dryRun)
        }

        if nativeMagic == mhMagic64 {
            return try patchThin(handle: handle, machOffset: 0, entries: entries, dryRun: dryRun)
        }

        throw ToolError.unsupportedMachO(fileURL.path)
    }

    private func patchFat(handle: FileHandle, is64BitFat: Bool, entries: [PatchEntry], dryRun: Bool) throws -> [PatchReport] {
        let nfat = Int(try handle.readData(at: 4, length: 4).beUInt32(at: 0))
        var offset: UInt64 = 8
        var reports: [PatchReport] = []

        for _ in 0..<nfat {
            let length = is64BitFat ? 32 : 20
            let data = try handle.readData(at: offset, length: length)
            let cpuType = Int32(bitPattern: data.beUInt32(at: 0))
            let sliceOffset = is64BitFat ? data.beUInt64(at: 8) : UInt64(data.beUInt32(at: 8))
            offset += UInt64(length)

            let matchingEntries = entries.filter { $0.arch.cpuType == cpuType }
            guard !matchingEntries.isEmpty else {
                continue
            }

            let sliceReports = try patchThin(handle: handle, machOffset: sliceOffset, entries: matchingEntries, dryRun: dryRun)
            reports.append(contentsOf: sliceReports)
        }

        if reports.isEmpty {
            throw ToolError.noMatchingSlice(fileURL.path)
        }

        return reports
    }

    private func patchThin(handle: FileHandle, machOffset: UInt64, entries: [PatchEntry], dryRun: Bool) throws -> [PatchReport] {
        let header = try handle.readData(at: machOffset, length: 32)
        guard header.leUInt32(at: 0) == mhMagic64 else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }

        let cpuType = Int32(bitPattern: header.leUInt32(at: 4))
        let ncmds = Int(header.leUInt32(at: 16))
        let matchingEntries = entries.filter { $0.arch.cpuType == cpuType }
        guard !matchingEntries.isEmpty else {
            return []
        }

        var reports: [PatchReport] = []
        for entry in matchingEntries {
            let mappedOffset = try mappedFileOffset(forAddress: entry.address, byteCount: entry.patchBytes.count, handle: handle, machOffset: machOffset, ncmds: ncmds)
            let actualBytes = try handle.readData(at: mappedOffset, length: entry.patchBytes.count)

            if actualBytes == entry.patchBytes {
                reports.append(PatchReport(arch: entry.arch, address: entry.address, fileOffset: mappedOffset, status: .alreadyPatched))
                continue
            }

            if !entry.expectedBytes.isEmpty && !entry.expectedBytes.contains(actualBytes) {
                throw ToolError.bytesMismatch(address: entry.address, expected: entry.expectedBytes, actual: actualBytes)
            }

            if dryRun {
                reports.append(PatchReport(arch: entry.arch, address: entry.address, fileOffset: mappedOffset, status: .wouldPatch))
            } else {
                try handle.seek(toOffset: mappedOffset)
                handle.write(entry.patchBytes)
                reports.append(PatchReport(arch: entry.arch, address: entry.address, fileOffset: mappedOffset, status: .patched))
            }
        }

        return reports
    }

    private func mappedFileOffset(forAddress address: UInt64, byteCount: Int, handle: FileHandle, machOffset: UInt64, ncmds: Int) throws -> UInt64 {
        var commandOffset = machOffset + 32
        for _ in 0..<ncmds {
            let command = try handle.readData(at: commandOffset, length: 8)
            let cmd = command.leUInt32(at: 0)
            let cmdsize = UInt64(command.leUInt32(at: 4))

            if cmd == lcSegment64 {
                let segment = try handle.readData(at: commandOffset, length: 72)
                let vmaddr = segment.leUInt64(at: 24)
                let vmsize = segment.leUInt64(at: 32)
                let fileoff = segment.leUInt64(at: 40)
                let filesize = segment.leUInt64(at: 48)
                let endAddress = address + UInt64(byteCount)

                if address >= vmaddr && endAddress <= vmaddr + vmsize {
                    let relative = address - vmaddr
                    if relative + UInt64(byteCount) <= filesize {
                        return machOffset + fileoff + relative
                    }
                }
            }

            commandOffset += cmdsize
        }

        throw ToolError.addressNotMapped(address: address, file: fileURL.path)
    }
}

final class MachODylibInjector {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func inject(installName: String, arch: CPUArch, dryRun: Bool) throws -> [DylibInjectionReport] {
        var data = try Data(contentsOf: fileURL)
        let reports = try inject(installName: installName, arch: arch, dryRun: dryRun, data: &data)

        if !dryRun && reports.contains(where: { $0.status == .injected }) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seek(toOffset: 0)
            handle.write(data)
        }

        return reports
    }

    private func inject(
        installName: String,
        arch: CPUArch,
        dryRun: Bool,
        data: inout Data
    ) throws -> [DylibInjectionReport] {
        guard data.count >= 4 else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }

        let nativeMagic = data.leUInt32(at: 0)
        let bigEndianMagic = data.beUInt32(at: 0)

        if bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64 {
            return try injectFat(
                installName: installName,
                arch: arch,
                is64BitFat: bigEndianMagic == fatMagic64,
                dryRun: dryRun,
                data: &data
            )
        }

        if nativeMagic == mhMagic64 {
            guard let report = try injectThin(
                installName: installName,
                arch: arch,
                machOffset: 0,
                machEnd: data.count,
                dryRun: dryRun,
                data: &data
            ) else {
                throw ToolError.noMatchingSlice(fileURL.path)
            }
            return [report]
        }

        throw ToolError.unsupportedMachO(fileURL.path)
    }

    private func injectFat(
        installName: String,
        arch: CPUArch,
        is64BitFat: Bool,
        dryRun: Bool,
        data: inout Data
    ) throws -> [DylibInjectionReport] {
        guard data.hasRange(offset: 0, length: 8) else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }

        let nfat = Int(data.beUInt32(at: 4))
        var offset = 8
        var reports: [DylibInjectionReport] = []

        for _ in 0..<nfat {
            let length = is64BitFat ? 32 : 20
            guard data.hasRange(offset: offset, length: length) else {
                throw ToolError.unsupportedMachO(fileURL.path)
            }
            let cpuType = Int32(bitPattern: data.beUInt32(at: offset))
            let sliceOffset = is64BitFat ? data.beUInt64(at: offset + 8) : UInt64(data.beUInt32(at: offset + 8))
            let sliceSize = is64BitFat ? data.beUInt64(at: offset + 16) : UInt64(data.beUInt32(at: offset + 12))
            offset += length

            guard cpuType == arch.cpuType else {
                continue
            }
            guard sliceOffset <= UInt64(Int.max),
                  sliceSize <= UInt64(Int.max),
                  sliceOffset <= UInt64(Int.max) - sliceSize,
                  data.hasRange(offset: Int(sliceOffset), length: Int(sliceSize)) else {
                throw ToolError.unsupportedMachO(fileURL.path)
            }
            let sliceEnd = Int(sliceOffset + sliceSize)

            if let report = try injectThin(
                installName: installName,
                arch: arch,
                machOffset: Int(sliceOffset),
                machEnd: sliceEnd,
                dryRun: dryRun,
                data: &data
            ) {
                reports.append(report)
            }
        }

        if reports.isEmpty {
            throw ToolError.noMatchingSlice(fileURL.path)
        }

        return reports
    }

    private func injectThin(
        installName: String,
        arch: CPUArch,
        machOffset: Int,
        machEnd: Int,
        dryRun: Bool,
        data: inout Data
    ) throws -> DylibInjectionReport? {
        guard data.hasRange(offset: machOffset, length: 32), machEnd <= data.count else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }
        guard data.leUInt32(at: machOffset) == mhMagic64 else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }

        let cpuType = Int32(bitPattern: data.leUInt32(at: machOffset + 4))
        guard cpuType == arch.cpuType else {
            return nil
        }

        let ncmds = Int(data.leUInt32(at: machOffset + 16))
        let sizeofcmds = Int(data.leUInt32(at: machOffset + 20))
        let commandStart = machOffset + 32
        let insertionOffset = commandStart + sizeofcmds
        guard commandStart <= insertionOffset,
              insertionOffset <= machEnd,
              data.hasRange(offset: commandStart, length: sizeofcmds) else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }

        var commandOffset = commandStart
        var firstContentOffset = Int.max
        for _ in 0..<ncmds {
            guard data.hasRange(offset: commandOffset, length: 8), commandOffset + 8 <= insertionOffset else {
                throw ToolError.unsupportedMachO(fileURL.path)
            }
            let cmd = data.leUInt32(at: commandOffset)
            let cmdsize = Int(data.leUInt32(at: commandOffset + 4))
            guard cmdsize >= 8,
                  commandOffset + cmdsize <= insertionOffset,
                  data.hasRange(offset: commandOffset, length: cmdsize) else {
                throw ToolError.unsupportedMachO(fileURL.path)
            }

            if cmd == lcLoadDylib {
                let nameOffset = Int(data.leUInt32(at: commandOffset + 8))
                guard nameOffset >= 24, nameOffset < cmdsize else {
                    throw ToolError.unsupportedMachO(fileURL.path)
                }
                let start = commandOffset + nameOffset
                let end = (start..<(commandOffset + cmdsize)).first { data[$0] == 0 } ?? commandOffset + cmdsize
                let existingName = String(data: data[start..<end], encoding: .utf8)
                if existingName == installName {
                    return DylibInjectionReport(
                        arch: arch,
                        installName: installName,
                        commandOffset: UInt64(commandOffset),
                        paddingLeft: UInt64(firstContentOffset == Int.max ? 0 : max(0, firstContentOffset - insertionOffset)),
                        status: .alreadyInjected
                    )
                }
            }

            if cmd == lcSegment64 {
                let sliceRelativeContentOffset = try firstSectionOffset(commandOffset: commandOffset, commandEnd: commandOffset + cmdsize, data: data)
                if sliceRelativeContentOffset != Int.max {
                    firstContentOffset = min(firstContentOffset, machOffset + sliceRelativeContentOffset)
                }
            }

            commandOffset += cmdsize
        }

        guard firstContentOffset != Int.max else {
            throw ToolError.invalidConfig("无法计算 \(fileURL.path) 的 Mach-O header padding")
        }

        let commandData = makeLoadDylibCommand(installName: installName)
        let availablePadding = firstContentOffset - insertionOffset
        guard commandData.count <= availablePadding else {
            throw ToolError.invalidConfig(
                "\(fileURL.lastPathComponent) 的 Mach-O header padding 不足，至少需要 \(commandData.count) 字节，实际只有 \(availablePadding) 字节"
            )
        }

        let report = DylibInjectionReport(
            arch: arch,
            installName: installName,
            commandOffset: UInt64(insertionOffset),
            paddingLeft: UInt64(availablePadding - commandData.count),
            status: dryRun ? .wouldInject : .injected
        )

        guard !dryRun else {
            return report
        }

        data.replaceSubrange(insertionOffset..<(insertionOffset + commandData.count), with: commandData)
        data.setLEUInt32(UInt32(ncmds + 1), at: machOffset + 16)
        data.setLEUInt32(UInt32(sizeofcmds + commandData.count), at: machOffset + 20)
        return report
    }

    private func firstSectionOffset(commandOffset: Int, commandEnd: Int, data: Data) throws -> Int {
        guard data.hasRange(offset: commandOffset, length: 72), commandOffset + 72 <= commandEnd else {
            throw ToolError.unsupportedMachO(fileURL.path)
        }
        let nsects = Int(data.leUInt32(at: commandOffset + 64))
        guard nsects > 0 else {
            let fileoff = Int(data.leUInt64(at: commandOffset + 40))
            return fileoff > 0 ? fileoff : Int.max
        }

        var result = Int.max
        var sectionOffset = commandOffset + 72
        for _ in 0..<nsects {
            guard data.hasRange(offset: sectionOffset, length: 80), sectionOffset + 80 <= commandEnd else {
                throw ToolError.unsupportedMachO(fileURL.path)
            }
            let offset = Int(data.leUInt32(at: sectionOffset + 48))
            if offset > 0 {
                result = min(result, offset)
            }
            sectionOffset += 80
        }
        return result
    }

    private func makeLoadDylibCommand(installName: String) -> Data {
        var data = Data()
        let pathBytes = Array(installName.utf8) + [0]
        let commandSize = alignedTo8(24 + pathBytes.count)

        data.append(contentsOf: littleEndianBytes(lcLoadDylib))
        data.append(contentsOf: littleEndianBytes(UInt32(commandSize)))
        data.append(contentsOf: littleEndianBytes(UInt32(24)))
        data.append(contentsOf: littleEndianBytes(UInt32(2)))
        data.append(contentsOf: littleEndianBytes(UInt32(0)))
        data.append(contentsOf: littleEndianBytes(UInt32(0)))
        data.append(contentsOf: pathBytes)

        if data.count < commandSize {
            data.append(contentsOf: Array(repeating: 0, count: commandSize - data.count))
        }

        return data
    }

    private func alignedTo8(_ value: Int) -> Int {
        (value + 7) & ~7
    }

    private func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ]
    }
}

enum MachOInspector {
    static func containsDylibSlice(data: Data, arch: CPUArch) -> Bool {
        guard data.count >= 4 else {
            return false
        }

        let nativeMagic = data.leUInt32(at: 0)
        let bigEndianMagic = data.beUInt32(at: 0)
        if bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64 {
            return containsFatDylibSlice(data: data, arch: arch, is64BitFat: bigEndianMagic == fatMagic64)
        }

        if nativeMagic == mhMagic64 {
            return isDylibSlice(data: data, machOffset: 0, machEnd: data.count, arch: arch)
        }

        return false
    }

    private static func containsFatDylibSlice(data: Data, arch: CPUArch, is64BitFat: Bool) -> Bool {
        guard data.count >= 8 else {
            return false
        }

        let nfat = Int(data.beUInt32(at: 4))
        var offset = 8
        for _ in 0..<nfat {
            let length = is64BitFat ? 32 : 20
            guard data.hasRange(offset: offset, length: length) else {
                return false
            }

            let cpuType = Int32(bitPattern: data.beUInt32(at: offset))
            let sliceOffset64 = is64BitFat ? data.beUInt64(at: offset + 8) : UInt64(data.beUInt32(at: offset + 8))
            let sliceSize64 = is64BitFat ? data.beUInt64(at: offset + 16) : UInt64(data.beUInt32(at: offset + 12))
            offset += length

            guard sliceOffset64 <= UInt64(Int.max),
                  sliceSize64 <= UInt64(Int.max),
                  sliceOffset64 <= UInt64(Int.max) - sliceSize64,
                  data.hasRange(offset: Int(sliceOffset64), length: Int(sliceSize64)) else {
                return false
            }
            let sliceOffset = Int(sliceOffset64)
            let sliceSize = Int(sliceSize64)
            if cpuType == arch.cpuType && isDylibSlice(data: data, machOffset: sliceOffset, machEnd: sliceOffset + sliceSize, arch: arch) {
                return true
            }
        }

        return false
    }

    private static func isDylibSlice(data: Data, machOffset: Int, machEnd: Int, arch: CPUArch) -> Bool {
        guard data.hasRange(offset: machOffset, length: 16), machEnd <= data.count else {
            return false
        }
        guard data.leUInt32(at: machOffset) == mhMagic64 else {
            return false
        }

        let cpuType = Int32(bitPattern: data.leUInt32(at: machOffset + 4))
        let fileType = data.leUInt32(at: machOffset + 12)
        return cpuType == arch.cpuType && fileType == mhDylib
    }
}

struct RuntimeTipInstaller {
    static let dylibFileName = "libWeChatAntiRecallRuntime.dylib"
    static let installName = "@loader_path/\(dylibFileName)"
    static let hostBinaryPath = "Contents/Resources/wechat.dylib"
    static let destinationDylibPath = "Contents/Resources/\(dylibFileName)"
    static let supportedBuildVersions = ["268597", "268599"]

    let sourceDylibURL: URL
    let destinationDylibURL: URL
    let hostBinaryURL: URL

    var destinationDylibRelativePath: String {
        Self.destinationDylibPath
    }

    init(appInfo: AppInfo, options: InstallOptions) throws {
        guard options.runtimeTip else {
            throw ToolError.invalidConfig("runtime-tip 未启用")
        }
        guard Self.supportedBuildVersions.contains(appInfo.buildVersion) else {
            throw ToolError.invalidConfig(
                "runtime-tip 目前只支持微信构建号 \(Self.supportedBuildVersions.joined(separator: ", "))，当前构建号是 \(appInfo.buildVersion)"
            )
        }

        sourceDylibURL = try Self.resolveSourceDylibURL(path: options.runtimeDylibPath)
        destinationDylibURL = appInfo.appURL.appendingPathComponent(Self.destinationDylibPath)
        hostBinaryURL = appInfo.appURL.appendingPathComponent(Self.hostBinaryPath)
    }

    func install(dryRun: Bool) throws -> [DylibInjectionReport] {
        let reports = try MachODylibInjector(fileURL: hostBinaryURL).inject(
            installName: Self.installName,
            arch: .arm64,
            dryRun: true
        )

        guard !dryRun else {
            return reports
        }

        try copyRuntimeDylib()
        return try MachODylibInjector(fileURL: hostBinaryURL).inject(
            installName: Self.installName,
            arch: .arm64,
            dryRun: false
        )
    }

    private static func resolveSourceDylibURL(path: String?) throws -> URL {
        let fileManager = FileManager.default
        if let path {
            let url = URL(fileURLWithPath: path)
            guard fileManager.isReadableFile(atPath: url.path) else {
                throw ToolError.invalidConfig("找不到 runtime dylib：\(path)")
            }
            try validateRuntimeDylib(at: url)
            return url
        }

        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let candidates = [
            executableDirectory.appendingPathComponent(Self.dylibFileName),
            workingDirectory.appendingPathComponent(".build/release/\(Self.dylibFileName)"),
            workingDirectory.appendingPathComponent(".build/debug/\(Self.dylibFileName)"),
            workingDirectory.appendingPathComponent(".build/arm64-apple-macosx/release/\(Self.dylibFileName)"),
            workingDirectory.appendingPathComponent(".build/arm64-apple-macosx/debug/\(Self.dylibFileName)")
        ]

        if let url = candidates.first(where: { fileManager.isReadableFile(atPath: $0.path) }) {
            try validateRuntimeDylib(at: url)
            return url
        }

        throw ToolError.usage("找不到 \(Self.dylibFileName)，请先运行 swift build -c release，或使用 --runtime-dylib <path>")
    }

    static func validateRuntimeDylib(at url: URL) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw ToolError.invalidRuntimeDylib(path: url.path, reason: "不允许使用符号链接")
        }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ToolError.invalidRuntimeDylib(path: url.path, reason: "必须是普通文件")
        }

        let data = try Data(contentsOf: url)
        guard MachOInspector.containsDylibSlice(data: data, arch: .arm64) else {
            throw ToolError.invalidRuntimeDylib(path: url.path, reason: "必须是包含 arm64 切片的 Mach-O dylib")
        }

        let symbols = try runProcessOutput("/usr/bin/nm", ["-gU", url.path])
        let requiredSymbols = [
            "wechat_antirecall_render_revoke_tip_copy",
            "wechat_antirecall_render_revoke_tip_for_event_copy",
            "wechat_antirecall_free"
        ]
        for symbol in requiredSymbols {
            guard symbols.contains(symbol) else {
                throw ToolError.invalidRuntimeDylib(path: url.path, reason: "缺少导出符号 \(symbol)")
            }
        }
    }

    private func copyRuntimeDylib() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destinationDylibURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationDylibURL.path) {
                try fileManager.removeItem(at: destinationDylibURL)
            }
            try fileManager.copyItem(at: sourceDylibURL, to: destinationDylibURL)
        } catch {
            throw ToolError.fileOperationFailed(
                operation: "安装 runtime dylib",
                path: destinationDylibURL.path,
                underlying: error.localizedDescription
            )
        }
    }
}

private func loadConfigs(path: String?) throws -> [VersionConfig] {
    let configURL = try resolveConfigURL(path: path)
    let data = try Data(contentsOf: configURL)
    return try JSONDecoder().decode([VersionConfig].self, from: data)
}

private func resolveConfigURL(path: String?) throws -> URL {
    if let path {
        return URL(fileURLWithPath: path)
    }

    let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("patches.json")
    if FileManager.default.fileExists(atPath: cwdURL.path) {
        return cwdURL
    }

    let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let executableConfig = executableDir.appendingPathComponent("patches.json")
    if FileManager.default.fileExists(atPath: executableConfig.path) {
        return executableConfig
    }

    throw ToolError.invalidConfig("找不到 patches.json，请使用 --config 指定路径")
}

private func readAppInfo(appPath: String) throws -> AppInfo {
    let appURL = URL(fileURLWithPath: appPath)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ToolError.notAWechatApp(appPath)
    }

    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
    let plistData = try Data(contentsOf: plistURL)
    var plistFormat = PropertyListSerialization.PropertyListFormat.xml
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: &plistFormat) as? [String: Any] else {
        throw ToolError.notAWechatApp(appPath)
    }

    guard let executable = plist["CFBundleExecutable"] as? String else {
        throw ToolError.appInfoMissing("CFBundleExecutable")
    }
    guard let shortVersion = plist["CFBundleShortVersionString"] as? String else {
        throw ToolError.appInfoMissing("CFBundleShortVersionString")
    }
    guard let buildVersion = plist["CFBundleVersion"] as? String else {
        throw ToolError.appInfoMissing("CFBundleVersion")
    }
    guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String else {
        throw ToolError.appInfoMissing("CFBundleIdentifier")
    }
    guard isSupportedWechatBundleIdentifier(bundleIdentifier) else {
        throw ToolError.notAWechatApp(appPath)
    }

    return AppInfo(
        appURL: appURL,
        executableURL: appURL.appendingPathComponent("Contents/MacOS/\(executable)"),
        shortVersion: shortVersion,
        buildVersion: buildVersion,
        bundleIdentifier: bundleIdentifier
    )
}

struct BundleIdentifierChange: Equatable {
    let relativePlistPath: String
    let oldIdentifier: String
    let newIdentifier: String
}

struct AppCloneRewriter {
    let appURL: URL
    let sourceMainBundleIdentifier: String
    let cloneToken: String

    func rewrite() throws -> [BundleIdentifierChange] {
        var changes: [BundleIdentifierChange] = []
        for plistURL in try Self.bundleInfoPlistURLs(in: appURL) {
            var (plist, format) = try readPropertyListDictionary(at: plistURL)
            guard let currentIdentifier = plist["CFBundleIdentifier"] as? String,
                  let clonedIdentifier = Self.clonedBundleIdentifier(
                    from: currentIdentifier,
                    sourceMainBundleIdentifier: sourceMainBundleIdentifier,
                    cloneToken: cloneToken
                  ),
                  clonedIdentifier != currentIdentifier else {
                continue
            }

            plist["CFBundleIdentifier"] = clonedIdentifier
            try writePropertyListDictionary(plist, format: format, to: plistURL)
            let relativePath = plistURL.path.replacingOccurrences(of: appURL.path + "/", with: "")
            changes.append(BundleIdentifierChange(
                relativePlistPath: relativePath,
                oldIdentifier: currentIdentifier,
                newIdentifier: clonedIdentifier
            ))
        }
        return changes
    }

    static func bundleInfoPlistURLs(in appURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "Info.plist", url.path.hasSuffix("/Contents/Info.plist") else {
                continue
            }
            urls.append(url)
        }
        return urls.sorted { $0.path < $1.path }
    }

    static func clonedBundleIdentifier(
        from original: String,
        sourceMainBundleIdentifier: String,
        cloneToken: String
    ) -> String? {
        var roots = [sourceMainBundleIdentifier, "com.tencent.xinWeChat", "com.tencent.xin", "com.tencent.flue", "com.tencent.xWechat"]
        roots = roots.reduce(into: []) { result, root in
            if !result.contains(root) {
                result.append(root)
            }
        }

        for root in roots {
            if original == root {
                return "\(root).\(cloneToken)"
            }

            let prefix = "\(root)."
            if original.hasPrefix(prefix) {
                return "\(root).\(cloneToken).\(original.dropFirst(prefix.count))"
            }
        }

        return nil
    }
}

private func isSupportedWechatBundleIdentifier(_ bundleIdentifier: String) -> Bool {
    let supportedRoots = ["com.tencent.xinWeChat", "com.tencent.xin"]
    return supportedRoots.contains(bundleIdentifier) || supportedRoots.contains { bundleIdentifier.hasPrefix("\($0).") }
}

private func validateClonePermissions(outputURL: URL) throws {
    try requireDirectoryWritable(outputURL.deletingLastPathComponent(), operation: "创建 WeChat 分身")
}

private func readPropertyListDictionary(at url: URL) throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
    let data = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.binary
    guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
        throw ToolError.fileOperationFailed(
            operation: "读取 Info.plist",
            path: url.path,
            underlying: "顶层对象不是字典"
        )
    }
    return (plist, format)
}

private func writePropertyListDictionary(
    _ plist: [String: Any],
    format: PropertyListSerialization.PropertyListFormat,
    to url: URL
) throws {
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try data.write(to: url, options: .atomic)
    } catch {
        throw ToolError.fileOperationFailed(
            operation: "写入 Info.plist",
            path: url.path,
            underlying: error.localizedDescription
        )
    }
}

private func configForInstalledApp(_ appInfo: AppInfo, configs: [VersionConfig]) throws -> VersionConfig {
    if let config = configs.first(where: { $0.version == appInfo.buildVersion }) {
        return config
    }
    throw ToolError.unsupportedVersion(found: appInfo.buildVersion, supported: configs.map(\.version))
}

private func validateInstallPermissions(
    appInfo: AppInfo,
    targets: [PatchTarget],
    options: InstallOptions,
    runtimeInstaller: RuntimeTipInstaller?
) throws {
    guard !options.dryRun else {
        return
    }

    for target in targets {
        let binaryURL = try BundleRelativePath.resolve(target.binaryPath, in: appInfo.appURL)
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            continue
        }

        try requireWritable(binaryURL, operation: "修改目标二进制")

        if !options.noBackup {
            try requireDirectoryWritable(binaryURL.deletingLastPathComponent(), operation: "在目标目录创建备份")
        }
    }

    if let runtimeInstaller {
        try requireWritable(runtimeInstaller.hostBinaryURL, operation: "注入 runtime 到目标二进制")
        try requireDirectoryWritable(
            runtimeInstaller.destinationDylibURL.deletingLastPathComponent(),
            operation: "安装 runtime dylib"
        )
    }

    if !options.skipResign {
        try requireDirectoryWritable(appInfo.appURL, operation: "重签名 WeChat.app")
    }
}

private func preflightInstall(appInfo: AppInfo, targets: [PatchTarget], runtimeInstaller: RuntimeTipInstaller?) throws {
    if let runtimeInstaller {
        _ = try runtimeInstaller.install(dryRun: true)
    }

    for target in targets {
        let binaryURL = try BundleRelativePath.resolve(target.binaryPath, in: appInfo.appURL)
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            throw ToolError.invalidConfig("找不到目标二进制：\(target.binaryPath)")
        }
        _ = try MachOPatcher(fileURL: binaryURL).patch(entries: target.entries, dryRun: true)
    }
}

private func printInstallRecoveryHints(appInfo: AppInfo, backupRecords: [BackupRecord]) {
    guard !backupRecords.isEmpty else {
        return
    }

    fputs("Install failed after creating backups. Restore commands:\n", stderr)
    for record in backupRecords {
        fputs(
            "  sudo .build/release/wechat-antirecall restore --app \(appInfo.appURL.path) --binary \(record.binaryPath) --backup \(record.backupURL.path)\n",
            stderr
        )
    }
}

private func validateRestorePermissions(appInfo: AppInfo, binaryURL: URL, skipResign: Bool) throws {
    try requireWritable(binaryURL, operation: "恢复目标二进制")

    if !skipResign {
        try requireDirectoryWritable(appInfo.appURL, operation: "重签名 WeChat.app")
    }
}

private func ensureAppNotRunning(appInfo: AppInfo, dryRun: Bool) throws {
    guard !dryRun else {
        return
    }

    let appPath = appInfo.appURL.standardizedFileURL.path
    let appPrefix = appPath.hasSuffix("/") ? appPath : "\(appPath)/"
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,comm="]
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError.commandFailed("/bin/ps -axo pid=,comm=", process.terminationStatus)
    }

    let text = String(data: output, encoding: .utf8) ?? ""
    let runningPIDs = text.split(separator: "\n").compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }

        let pid = String(trimmed[..<separator])
        let command = String(trimmed[separator...]).trimmingCharacters(in: .whitespaces)
        if command == appPath || command.hasPrefix(appPrefix) {
            return pid
        }
        return nil
    }

    if !runningPIDs.isEmpty {
        throw ToolError.appIsRunning(path: appInfo.appURL.path, pids: runningPIDs)
    }
}

private func requireWritable(_ url: URL, operation: String) throws {
    if access(url.path, W_OK) != 0 {
        throw ToolError.permissionDenied(path: url.path, operation: operation)
    }
}

private func requireDirectoryWritable(_ url: URL, operation: String) throws {
    try requireWritable(url, operation: operation)

    let probeURL = url.appendingPathComponent(".wechat-antirecall-write-test-\(UUID().uuidString)")
    do {
        try Data().write(to: probeURL, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probeURL)
    } catch {
        try? FileManager.default.removeItem(at: probeURL)
        throw ToolError.fileOperationFailed(
            operation: operation,
            path: url.path,
            underlying: error.localizedDescription
        )
    }
}

private func makeBackup(of fileURL: URL) throws -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let suffix = formatter.string(from: Date())
    let backupURL = fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("\(fileURL.lastPathComponent).wechat-antirecall-backup-\(suffix)")

    do {
        let data = try Data(contentsOf: fileURL)
        try data.write(to: backupURL, options: .withoutOverwriting)
    } catch {
        throw ToolError.fileOperationFailed(
            operation: "创建备份",
            path: backupURL.path,
            underlying: error.localizedDescription
        )
    }

    return backupURL
}

private func resign(appURL: URL, nestedBinaries: [URL]) throws {
    for binaryURL in uniqueURLs(nestedBinaries) {
        try signMachO(at: binaryURL)
    }

    _ = runProcessStatus("/usr/bin/codesign", ["--remove-sign", appURL.path])
    try runCodesign(at: appURL.path, deep: true)
    try runProcess("/usr/bin/xattr", ["-cr", appURL.path])
}

private func signMachO(at url: URL) throws {
    _ = runProcessStatus("/usr/bin/codesign", ["--remove-sign", url.path])
    do {
        try runCodesign(at: url.path, deep: false)
        return
    } catch {
    }

    try signMachOUsingTemporaryCopy(at: url)
}

private func signMachOUsingTemporaryCopy(at url: URL) throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wechat-antirecall-sign-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let temporaryURL = temporaryDirectory.appendingPathComponent(url.lastPathComponent)
    try FileManager.default.copyItem(at: url, to: temporaryURL)
    _ = runProcessStatus("/usr/bin/codesign", ["--remove-sign", temporaryURL.path])
    try runCodesign(at: temporaryURL.path, deep: false)
    try runProcess("/bin/cp", ["-p", temporaryURL.path, url.path])
}

private func runCodesign(at path: String, deep: Bool) throws {
    let baseArguments = ["--force"] + (deep ? ["--deep"] : [])
    let preservedArguments = baseArguments + ["--preserve-metadata=\(codesignPreservedMetadata)", "--sign", "-", path]
    if runProcessStatus("/usr/bin/codesign", preservedArguments) == 0 {
        return
    }

    try runProcess("/usr/bin/codesign", baseArguments + ["--sign", "-", path])
}

private func uniqueURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []

    for url in urls {
        let path = url.standardizedFileURL.path
        if seen.insert(path).inserted {
            result.append(url)
        }
    }

    return result
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw ToolError.commandFailed(([executable] + arguments).joined(separator: " "), process.terminationStatus)
    }
}

private func runProcessStatus(_ executable: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return 127
    }
}

private func runProcessOutput(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError.commandFailed(([executable] + arguments).joined(separator: " "), process.terminationStatus)
    }
    return String(data: output, encoding: .utf8) ?? ""
}

extension FileHandle {
    func readData(at offset: UInt64, length: Int) throws -> Data {
        try seek(toOffset: offset)
        let data = readData(ofLength: length)
        guard data.count == length else {
            throw ToolError.unsupportedMachO("unexpected EOF")
        }
        return data
    }
}

extension Data {
    func hasRange(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    init(hexString: String) throws {
        let cleaned = hexString.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else {
            throw ToolError.invalidHex(hexString)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = String(cleaned[index..<nextIndex])
            guard let byte = UInt8(byteString, radix: 16) else {
                throw ToolError.invalidHex(hexString)
            }
            bytes.append(byte)
            index = nextIndex
        }

        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func beUInt32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    func leUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<8 {
            value |= UInt64(self[offset + byteIndex]) << (byteIndex * 8)
        }
        return value
    }

    func beUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<8 {
            value = (value << 8) | UInt64(self[offset + byteIndex])
        }
        return value
    }

    mutating func setLEUInt32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xff)
        self[offset + 1] = UInt8((value >> 8) & 0xff)
        self[offset + 2] = UInt8((value >> 16) & 0xff)
        self[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}

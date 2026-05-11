import Foundation
import Darwin

private let defaultAppPath = "/Applications/WeChat.app"
private let defaultBinaryPath = "Contents/MacOS/WeChat"
private let lcSegment64: UInt32 = 0x19
private let mhMagic64: UInt32 = 0xfeedfacf
private let fatMagic: UInt32 = 0xcafebabe
private let fatMagic64: UInt32 = 0xcafebabf
private let cpuTypeX8664: Int32 = 0x01000007
private let cpuTypeARM64: Int32 = 0x0100000c

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
        let targetIdentifiers = options.targetIdentifiers
        let targets = try targetIdentifiers.map { identifier in
            guard let target = config.targets.first(where: { $0.identifier == identifier }) else {
                throw ToolError.invalidConfig("构建号 \(config.version) 没有 \(identifier) 目标")
            }
            return target
        }
        var patchedBinaries: [URL] = []
        var backedUpBinaryPaths = Set<String>()

        print("WeChat: \(appInfo.shortVersion) (\(appInfo.buildVersion))")
        let modeText = targetIdentifiers.map(displayName(forTargetIdentifier:)).joined(separator: ", ")
        print(options.dryRun ? "Mode: dry-run (\(modeText))" : "Mode: \(modeText)")
        try ensureAppNotRunning(appInfo: appInfo, dryRun: options.dryRun)
        try validateInstallPermissions(appInfo: appInfo, targets: targets, options: options)

        for target in targets {
            let binaryURL = appInfo.appURL.appendingPathComponent(target.binaryPath)
            if !FileManager.default.fileExists(atPath: binaryURL.path) {
                throw ToolError.invalidConfig("找不到目标二进制：\(target.binaryPath)")
            }
            patchedBinaries.append(binaryURL)

            if !options.dryRun && !options.noBackup && backedUpBinaryPaths.insert(binaryURL.standardizedFileURL.path).inserted {
                let backupURL = try makeBackup(of: binaryURL)
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

    private func restore(_ arguments: [String]) throws {
        let options = try RestoreOptions(arguments)
        let appInfo = try readAppInfo(appPath: options.appPath)
        let binaryURL = appInfo.appURL.appendingPathComponent(options.binaryPath)
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

    private func printUsage() {
        print("""
        wechat-antirecall

        Usage:
          wechat-antirecall versions [--app /Applications/WeChat.app] [--config patches.json]
          wechat-antirecall install  [--app /Applications/WeChat.app] [--config patches.json] [--with-tip] [--block-update] [--update-only] [--dry-run] [--no-backup] [--skip-resign]
          wechat-antirecall restore  --backup <path> [--binary Contents/MacOS/WeChat] [--app /Applications/WeChat.app] [--skip-resign]

        Notes:
          install only patches versions present in patches.json.
          unknown WeChat builds are refused instead of guessed.
        """)
    }
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
    var blockUpdate = false
    var updateOnly = false
    var dryRun = false
    var noBackup = false
    var skipResign = false

    var targetIdentifiers: [String] {
        if updateOnly {
            return ["update"]
        }

        var identifiers = [withTip ? "revoke-tip" : "revoke"]
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
    default:
        return identifier
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
    guard bundleIdentifier == "com.tencent.xinWeChat" || bundleIdentifier == "com.tencent.xin" else {
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

private func configForInstalledApp(_ appInfo: AppInfo, configs: [VersionConfig]) throws -> VersionConfig {
    if let config = configs.first(where: { $0.version == appInfo.buildVersion }) {
        return config
    }
    throw ToolError.unsupportedVersion(found: appInfo.buildVersion, supported: configs.map(\.version))
}

private func validateInstallPermissions(appInfo: AppInfo, targets: [PatchTarget], options: InstallOptions) throws {
    guard !options.dryRun else {
        return
    }

    for target in targets {
        let binaryURL = appInfo.appURL.appendingPathComponent(target.binaryPath)
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            continue
        }

        try requireWritable(binaryURL, operation: "修改目标二进制")

        if !options.noBackup {
            try requireDirectoryWritable(binaryURL.deletingLastPathComponent(), operation: "在目标目录创建备份")
        }
    }

    if !options.skipResign {
        try requireDirectoryWritable(appInfo.appURL, operation: "重签名 WeChat.app")
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
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError.commandFailed("/bin/ps -axo pid=,comm=", process.terminationStatus)
    }

    let output = pipe.fileHandleForReading.readDataToEndOfFile()
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

    try runProcess("/usr/bin/codesign", ["--remove-sign", appURL.path])
    try runProcess("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", appURL.path])
    try runProcess("/usr/bin/xattr", ["-cr", appURL.path])
}

private func signMachO(at url: URL) throws {
    _ = runProcessStatus("/usr/bin/codesign", ["--remove-sign", url.path])
    if runProcessStatus("/usr/bin/codesign", ["--force", "--sign", "-", url.path]) == 0 {
        return
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
    try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", temporaryURL.path])
    try runProcess("/bin/cp", ["-p", temporaryURL.path, url.path])
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
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        return 127
    }
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
}

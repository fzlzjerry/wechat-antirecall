import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let defaultAppPath = "/Applications/WeChat.app"
    private static let selectedAppPathKey = "selectedWeChatAppPath"

    // Target
    @Published private(set) var appPath: String

    // Status
    @Published var versions: VersionsReport?
    @Published var directInfo: DirectAppInfo?
    @Published var supportStatus: SupportStatus = .unknown
    @Published var installState: InstallState = .unknown
    @Published var updateBlockState: InstallState = .unknown
    @Published var installedMode: InstallMode?
    @Published var customTipNeedsRestore: Bool = false
    @Published var wechatRunning: Bool = false

    // Activity
    @Published var busy: Bool = false
    @Published var busyMessage: String = ""
    @Published var banner: Banner?
    @Published var logLines: [String] = []

    private var runningPoll: Task<Void, Never>?
    private let defaults: UserDefaults
    private var statusRevision: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.selectedAppPathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            appPath = saved
        } else {
            appPath = Self.defaultAppPath
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        BundledPaths.ensureWorkingDirectories()
        startRunningPoll()
        Task { await refresh() }
    }

    private func startRunningPoll() {
        runningPoll?.cancel()
        runningPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                wechatRunning = WeChatStatusProbe.isRunning(appPath: appPath)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Derived

    var displayBuild: String {
        versions?.app.installedBuild ?? directInfo?.installedBuild ?? "—"
    }

    var displayVersion: String {
        versions?.app.marketingVersion ?? directInfo?.marketingVersion ?? "—"
    }

    var runtimeTipSupported: Bool { versions?.runtimeTipSupported ?? false }
    var silentAvailable: Bool { versions?.features.silent ?? false }
    var customTipAvailable: Bool {
        guard let versions else { return false }
        return versions.runtimeTipSupported && versions.features.customTip && versions.features.tip
    }
    var customTipRuntimeOutdated: Bool {
        guard let versions else { return false }
        return versions.supported
            && versions.features.tip
            && versions.installedBuildTargets.contains("revoke-tip")
            && versions.installedBuildTargets.contains("runtime-tip")
            && !versions.runtimeTipSupported
    }
    var updateOnlyAvailable: Bool { versions?.features.blockUpdate ?? false }

    func isInstallModeAvailable(_ mode: InstallMode) -> Bool {
        switch mode {
        case .silent:
            return silentAvailable
        case .customTip:
            return customTipAvailable
        case .updateOnly:
            return updateOnlyAvailable
        }
    }

    var effectiveCatalogSourceIsDownloaded: Bool { BundledPaths.usingDownloadedCatalog }

    var isUsingDefaultAppPath: Bool {
        URL(fileURLWithPath: appPath).standardizedFileURL.path
            == URL(fileURLWithPath: Self.defaultAppPath).standardizedFileURL.path
    }

    private func beginStatusRequest() -> UInt64 {
        statusRevision &+= 1
        return statusRevision
    }

    private func statusRequestIsCurrent(_ revision: UInt64, appPath expectedPath: String) -> Bool {
        statusRevision == revision && appPath == expectedPath
    }

    func selectTargetApp(at url: URL) async {
        guard !busy else { return }
        busy = true
        busyMessage = "正在验证所选微信…"
        banner = nil
        defer {
            busy = false
            busyMessage = ""
        }

        let candidate = url.standardizedFileURL.path
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              WeChatStatusProbe.appExists(at: candidate),
              let info = WeChatStatusProbe.readInfo(appPath: candidate) else {
            banner = Banner(
                kind: .error,
                title: "无法选择此 App",
                message: "请选择一个完整、可读取的 macOS 微信 App。")
            return
        }
        guard WeChatStatusProbe.officialBundleIDs.contains(info.bundleIdentifier) else {
            banner = Banner(
                kind: .error,
                title: "不是官方微信",
                message: "本轮目标选择仅支持官方 macOS 微信（com.tencent.xinWeChat / com.tencent.xin）。多开副本不会作为补丁安装或备份恢复目标。")
            return
        }

        do {
            let report = try await versionsReport(appPath: candidate)
            let snapshot = try await statusSnapshot(for: report, appPath: candidate)

            _ = beginStatusRequest()
            appPath = candidate
            defaults.set(candidate, forKey: Self.selectedAppPathKey)
            apply(report, snapshot: snapshot)
            wechatRunning = WeChatStatusProbe.isRunning(appPath: candidate)
        } catch {
            banner = Banner(kind: .error, title: "无法使用所选微信", message: error.localizedDescription)
        }
    }

    func resetTargetApp() async {
        guard !busy else { return }
        busy = true
        busyMessage = "正在恢复默认微信…"
        _ = beginStatusRequest()
        appPath = Self.defaultAppPath
        defaults.removeObject(forKey: Self.selectedAppPathKey)
        await refresh()
        busy = false
        busyMessage = ""
    }

    // MARK: - Refresh

    func refresh(preserveBanner: Bool = false) async {
        let targetPath = appPath
        let revision = beginStatusRequest()
        if !preserveBanner { banner = nil }
        supportStatus = .unknown
        versions = nil
        directInfo = nil
        installState = .unknown
        updateBlockState = .unknown
        installedMode = nil
        customTipNeedsRestore = false
        wechatRunning = WeChatStatusProbe.isRunning(appPath: targetPath)

        guard WeChatStatusProbe.appExists(at: targetPath) else {
            versions = nil
            directInfo = nil
            supportStatus = .noWeChat
            installState = .unknown
            updateBlockState = .unknown
            installedMode = nil
            customTipNeedsRestore = false
            return
        }

        guard let info = WeChatStatusProbe.readInfo(appPath: targetPath) else {
            versions = nil
            directInfo = nil
            supportStatus = .failed
            installState = .unknown
            updateBlockState = .unknown
            installedMode = nil
            customTipNeedsRestore = false
            banner = Banner(
                kind: .error,
                title: "无法读取所选 App",
                message: "所选路径存在，但不是完整、可读取的 macOS App。请在首页重新选择官方微信。")
            return
        }

        directInfo = info
        guard WeChatStatusProbe.officialBundleIDs.contains(info.bundleIdentifier) else {
            versions = nil
            supportStatus = .failed
            installState = .unknown
            updateBlockState = .unknown
            installedMode = nil
            customTipNeedsRestore = false
            banner = Banner(
                kind: .error,
                title: "所选 App 不是官方微信",
                message: "请在首页重新选择官方 macOS 微信。本轮不会对多开副本执行安装或恢复。")
            return
        }

        do {
            let report = try await versionsReport(appPath: targetPath)
            let snapshot = try await statusSnapshot(for: report, appPath: targetPath)
            guard statusRequestIsCurrent(revision, appPath: targetPath) else { return }
            apply(report, snapshot: snapshot)
        } catch {
            guard statusRequestIsCurrent(revision, appPath: targetPath) else { return }
            versions = nil
            directInfo = info
            supportStatus = .failed
            installState = .unknown
            updateBlockState = .unknown
            installedMode = nil
            customTipNeedsRestore = false
            banner = Banner(
                kind: .error,
                title: "检测失败",
                message: "\(error.localizedDescription) 请确认 App 文件完整；若问题持续，请重新安装本工具并查看下方日志。")
        }
    }

    private struct StatusSnapshot {
        let supportStatus: SupportStatus
        let installState: InstallState
        let updateBlockState: InstallState
        let installedMode: InstallMode?
        let customTipNeedsRestore: Bool
    }

    private func apply(_ report: VersionsReport, snapshot: StatusSnapshot) {
        versions = report
        directInfo = nil
        supportStatus = snapshot.supportStatus
        installState = snapshot.installState
        updateBlockState = snapshot.updateBlockState
        installedMode = snapshot.installedMode
        customTipNeedsRestore = snapshot.customTipNeedsRestore
    }

    /// Uses unprivileged dry-runs to distinguish the mutually exclusive anti-recall modes
    /// and independently determine whether the automatic-update patch is installed.
    private func statusSnapshot(for report: VersionsReport, appPath: String) async throws -> StatusSnapshot {
        guard report.supported else {
            return StatusSnapshot(
                supportStatus: .unsupported(build: report.app.installedBuild),
                installState: .unknown,
                updateBlockState: .unknown,
                installedMode: nil,
                customTipNeedsRestore: false)
        }

        var antiRecallState = InstallState.unknown
        var mode: InstallMode?
        var customTipNeedsRestore = false
        let customAvailable = report.runtimeTipSupported
            && report.features.customTip
            && report.features.tip

        if customAvailable {
            let customState = try await dryRunProbe(
                for: InstallRequest(mode: .customTip),
                appPath: appPath
            ).installState
            switch customState {
            case .installed:
                antiRecallState = .installed
                mode = .customTip
            case .mismatch:
                antiRecallState = .mismatch
                customTipNeedsRestore = true
            case .notInstalled, .unknown:
                break
            }
        }

        if antiRecallState == .unknown && report.features.silent {
            let silentProbe = try await dryRunProbe(
                for: InstallRequest(mode: .silent),
                appPath: appPath)
            antiRecallState = silentProbe.installState
            if antiRecallState == .installed {
                mode = .silent
            }
        }

        let updateState: InstallState
        if report.features.blockUpdate {
            updateState = try await dryRunProbe(
                for: InstallRequest(mode: .updateOnly),
                appPath: appPath
            ).installState
        } else {
            updateState = .unknown
        }

        return StatusSnapshot(
            supportStatus: .supported,
            installState: antiRecallState,
            updateBlockState: updateState,
            installedMode: mode,
            customTipNeedsRestore: customTipNeedsRestore)
    }

    private enum InstallProbe {
        case report(InstallReport)
        case mismatch

        var installState: InstallState {
            switch self {
            case .mismatch:
                return .mismatch
            case .report(let report):
                return InstallState.classify(report)
            }
        }
    }

    private func dryRunProbe(for request: InstallRequest, appPath: String) async throws -> InstallProbe {
        let args = request.arguments(
            appPath: appPath,
            configURL: BundledPaths.effectivePatchesJSON,
            runtimeDylibURL: BundledPaths.runtimeDylib,
            dryRun: true)
        let result = await CLIRunner.runUser(BundledPaths.cli, args)
        if result.exitCode != 0 {
            if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
                if quarantineStaleBuiltCLI(envelope.schemaVersion) {
                    return try await dryRunProbe(for: request, appPath: appPath)
                }
                try requireSupportedSchema(envelope.schemaVersion)
                if envelope.error.kind == "bytesMismatch" { return .mismatch }
                throw GUIError(envelope.error.message)
            }
            throw GUIError(commandFailureMessage(result, operation: "检查补丁状态"))
        }
        // A stale source-built CLI can exit 0 with an outdated schema; retry with
        // the bundled binary before surfacing the mismatch.
        if let raw = try? JSONDecoder().decode(InstallReport.self, from: Data(result.output.utf8)),
           raw.command == "install", quarantineStaleBuiltCLI(raw.schemaVersion) {
            return try await dryRunProbe(for: request, appPath: appPath)
        }
        return .report(try decodeInstallReport(result.output))
    }

    private func versionsReport(appPath: String) async throws -> VersionsReport {
        let cliURL = BundledPaths.cli
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            throw GUIError("找不到可执行的内置命令行工具：\(cliURL.path)。")
        }
        let configURL = BundledPaths.effectivePatchesJSON
        guard BundledPaths.isValidCatalog(configURL) else {
            throw GUIError("补丁数据不可读取或格式无效：\(configURL.path)。")
        }

        let result = await CLIRunner.runUser(cliURL, [
            "versions", "--app", appPath, "--config", configURL.path, "--json",
        ])
        guard result.exitCode == 0 else {
            if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
                if quarantineStaleBuiltCLI(envelope.schemaVersion) {
                    return try await versionsReport(appPath: appPath)
                }
                try requireSupportedSchema(envelope.schemaVersion)
                throw GUIError(envelope.error.message)
            }
            throw GUIError(commandFailureMessage(result, operation: "读取微信版本"))
        }
        guard let report = try? JSONDecoder().decode(VersionsReport.self, from: Data(result.output.utf8)) else {
            throw GUIError("命令行工具返回了无法解析的版本信息。")
        }
        if quarantineStaleBuiltCLI(report.schemaVersion) {
            return try await versionsReport(appPath: appPath)
        }
        try requireSupportedSchema(report.schemaVersion)
        return report
    }

    private func decodeInstallReport(_ output: String) throws -> InstallReport {
        guard let report = try? JSONDecoder().decode(InstallReport.self, from: Data(output.utf8)),
              report.command == "install" else {
            throw GUIError("命令行工具返回了无法解析的安装检查结果。")
        }
        try requireSupportedSchema(report.schemaVersion)
        return report
    }

    private func requireSupportedSchema(_ schemaVersion: Int) throws {
        guard schemaVersion == GUICLIProtocol.schemaVersion else {
            throw GUIError(
                "命令行接口版本不兼容（GUI 支持 \(GUICLIProtocol.schemaVersion)，工具返回 \(schemaVersion)）。")
        }
    }

    /// A source-built CLI from an older release keeps reporting its old schema
    /// after an app upgrade, which would fail every GUI operation until the user
    /// manually reverts. Quarantine the stale binary once so `BundledPaths.cli`
    /// resolves to the bundled binary again. Returns true when a stale binary
    /// was actually moved aside (bounds any retry to a single extra attempt).
    @discardableResult
    private func quarantineStaleBuiltCLI(_ reportedSchemaVersion: Int) -> Bool {
        guard reportedSchemaVersion < GUICLIProtocol.schemaVersion,
              BundledPaths.usingBuiltFromSource else { return false }
        let stale = BundledPaths.builtDir.appendingPathComponent("wechat-antirecall")
        guard FileManager.default.isExecutableFile(atPath: stale.path) else { return false }
        let suffix = ".stale-schema\(reportedSchemaVersion)-\(Int(Date().timeIntervalSince1970))"
        let quarantined = BundledPaths.builtDir.appendingPathComponent("wechat-antirecall\(suffix)")
        do {
            try FileManager.default.moveItem(at: stale, to: quarantined)
        } catch {
            return false
        }
        // The source-built runtime dylib belongs to the same stale build; move it
        // too, or "安装或更新运行组件" would keep installing the outdated dylib
        // and the bundled CLI would keep reporting runtimeAvailable == false.
        let staleDylib = BundledPaths.builtDir.appendingPathComponent("libWeChatAntiRecallRuntime.dylib")
        if FileManager.default.fileExists(atPath: staleDylib.path) {
            try? FileManager.default.moveItem(
                at: staleDylib,
                to: BundledPaths.builtDir.appendingPathComponent("libWeChatAntiRecallRuntime.dylib\(suffix)"))
        }
        usingBuiltFromSource = BundledPaths.usingBuiltFromSource
        return true
    }

    private func commandFailureMessage(_ result: CLIResult, operation: String) -> String {
        let detail = (result.stderr + "\n" + result.output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "\(operation)失败（退出码 \(result.exitCode)）。"
            : "\(operation)失败：\(detail)"
    }

    // MARK: - Quit WeChat

    func quitWeChat() async {
        guard !busy else { return }
        busy = true
        busyMessage = "正在退出所选微信…"
        await WeChatStatusProbe.quit(appPath: appPath)
        wechatRunning = WeChatStatusProbe.isRunning(appPath: appPath)
        busy = false
        busyMessage = ""
    }

    // MARK: - Install

    // MARK: - Install access

    enum InstallAccess: Equatable {
        case writableAsUser   // this app can patch WeChat directly (has disk access) — no password
        case needsElevation   // WeChat.app owned by root/other — use osascript-admin
        case blockedByTCC     // WeChat.app owned by us but not writable — grant Full Disk Access
    }

    /// Shown when App Management/TCC blocks this (ad-hoc) app from modifying a user-owned WeChat.app.
    private func fullDiskAccessBanner() -> Banner {
        Banner(
            kind: .warning,
            title: "需要「完全磁盘访问」",
            message: "macOS 的「App 管理」阻止本 App 修改微信。请在「系统设置 → 隐私与安全性 → 完全磁盘访问」里把本 App 加进去并打开，然后「退出并重新打开本 App」再重试——新授权对已在运行的 App 不生效，必须重启本 App。（每次重新打补丁或微信升级后签名会变，可能需要在列表里重新添加。）",
            settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            settingsButtonTitle: "打开完全磁盘访问设置")
    }

    /// Attempts an unprivileged write into WeChat.app to decide how to install. WeChat.app is
    /// usually user-owned; a failed write there almost always means App Management/TCC is blocking
    /// this (ad-hoc-signed) app rather than a genuine ownership problem — in which case elevating
    /// wouldn't help (an osascript-admin child is blocked by the same TCC identity).
    static func probeInstallAccess(appPath: String) -> InstallAccess {
        let fm = FileManager.default
        let resources = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources", isDirectory: true)
        let probe = resources.appendingPathComponent(".wechat-antirecall-access-probe-\(UUID().uuidString)")
        if (try? Data().write(to: probe, options: .withoutOverwriting)) != nil {
            try? fm.removeItem(at: probe)
            return .writableAsUser
        }
        if let uid = (try? fm.attributesOfItem(atPath: appPath))?[.ownerAccountID] as? NSNumber,
           uid.uint32Value == getuid() {
            return .blockedByTCC
        }
        return .needsElevation
    }

    /// A real create/remove probe avoids assuming that POSIX mode bits reflect sandbox/TCC access.
    static func canWriteCloneOutputDirectory(_ path: String) -> Bool {
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory = ObjCBool(false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        let probe = directory.appendingPathComponent(".wechat-antirecall-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try fm.removeItem(at: probe)
            return true
        } catch {
            try? fm.removeItem(at: probe)
            return false
        }
    }

    /// The one-click flow: verify WeChat is quit, dry-run to confirm every byte matches,
    /// then elevate for the real install. Any byte mismatch aborts before touching the app.
    func install(_ request: InstallRequest, refreshRuntime: Bool = false) async {
        guard !busy else { return }
        banner = nil
        appendLog("——— 开始：\(request.mode.title) ———")
        if customTipNeedsRestore {
            banner = Banner(
                kind: .warning,
                title: "请先恢复自定义提示状态",
                message: "检测到不完整或混合的自定义提示运行时状态。在还原对应备份前，不能安装或检查任何模式，以免再次备份或重签名这个残留状态。")
            return
        }
        guard isInstallModeAvailable(request.mode) else {
            banner = Banner(
                kind: .warning,
                title: "当前模式不可用",
                message: "所选微信版本没有完整提供「\(request.mode.title)」所需的补丁能力。请勿继续安装。")
            return
        }

        // A custom-tip install changes additional bytes and injects a runtime dylib. Applying
        // only the silent branch patch on top would leave those pieces behind and create a mixed
        // installation. Force a full backup restore before switching in that direction.
        if installedMode == .customTip && request.mode == .silent {
            banner = Banner(
                kind: .warning,
                title: "请先恢复再切换模式",
                message: "当前是「自定义提示」模式。请先到「恢复 / 卸载」还原最近一次备份，再安装「静默防撤回」，避免残留运行时 hook。")
            return
        }

        if WeChatStatusProbe.isRunning(appPath: appPath) {
            banner = Banner(kind: .warning, title: "请先退出微信", message: "安装前需要完全退出微信，避免签名失效导致崩溃。")
            return
        }

        busy = true
        defer { busy = false; busyMessage = "" }

        let configURL = BundledPaths.effectivePatchesJSON
        let dylibURL = BundledPaths.runtimeDylib

        // 1) Dry-run (unprivileged, side-effect free).
        busyMessage = "正在检查补丁点…"
        let dryArgs = request.arguments(appPath: appPath, configURL: configURL, runtimeDylibURL: dylibURL, dryRun: true)
        let dry = await CLIRunner.runUser(BundledPaths.cli, dryArgs, onLine: { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        })

        if dry.exitCode != 0 {
            let message = decodeErrorMessage(from: dry) ?? dry.stderr
            banner = Banner(kind: .error, title: "检查未通过", message: message.isEmpty ? "补丁点检查失败。" : message)
            appendLog("检查失败：\(message)")
            return
        }
        let report: InstallReport
        do {
            report = try decodeInstallReport(dry.output)
        } catch {
            banner = Banner(kind: .error, title: "检查结果不可用", message: error.localizedDescription)
            appendLog("检查结果无效：\(error.localizedDescription)")
            return
        }
        switch InstallPreflightDisposition.classify(report) {
        case .invalid:
            banner = Banner(kind: .error, title: "检查结果无效", message: "安装检查没有返回有效步骤，或包含无法安全继续的状态。请先查看日志并还原对应备份。")
            return
        case .alreadyInstalled:
            // The loader/patches may be current while the bundled runtime predates
            // a new feature. The explicit runtime-update action must replace it.
            if refreshRuntime && request.mode == .customTip { break }
            banner = Banner(kind: .info, title: "已经开启", message: "\(request.mode.title)已经在生效中，无需重复安装。")
            if request.mode != .updateOnly {
                installState = .installed
                installedMode = request.mode
            } else {
                updateBlockState = .installed
            }
            return
        case .installable:
            break
        }

        // 2) Real install. The real install emits progress; keep --json off the human log so
        // codesign noise doesn't matter — we judge success by exit code.
        var realArgs = request.arguments(appPath: appPath, configURL: configURL, runtimeDylibURL: dylibURL, dryRun: false)
        realArgs.removeAll { $0 == "--json" }

        // Pre-flight access probe (fixes "green dry-run → password prompt → 安装失败"). WeChat.app
        // is usually owned by the current user, and the real blocker is App Management TCC, not
        // Unix perms — so if this app has Full Disk Access we can patch directly with no password
        // AND without the murky TCC attribution of an osascript-admin child. Only fall back to
        // elevation when the bundle is genuinely owned by root.
        let real: CLIResult
        switch Self.probeInstallAccess(appPath: appPath) {
        case .blockedByTCC:
            banner = fullDiskAccessBanner()
            appendLog("安装前检查失败：微信归当前用户但无写入权限（被 App 管理/TCC 拦截）。需授予完全磁盘访问。")
            return
        case .writableAsUser:
            busyMessage = "正在安装…"
            appendLog("安装前检查：可直接写入，无需管理员密码。")
            real = await CLIRunner.runUser(BundledPaths.cli, realArgs, onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            })
        case .needsElevation:
            busyMessage = "正在安装（需要管理员密码）…"
            real = await CLIRunner.runAdmin(BundledPaths.cli, realArgs, operation: "install", onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            })
        }

        if real.cancelled {
            banner = Banner(kind: .info, title: "已取消", message: "你取消了管理员授权，未做任何修改。")
            return
        }
        if real.succeeded {
            banner = Banner(kind: .success, title: "\(request.mode.title) 已开启",
                            message: "请完全退出并重新打开微信。首次使用建议用另一账号发消息再撤回，验证效果。")
            await refresh(preserveBanner: true)
        } else {
            let message = friendlyFailure(real)
            banner = Banner(kind: .error, title: "安装失败", message: message)
            appendLog("安装失败（退出码 \(real.exitCode)）")
        }
    }

    /// Dry-run only (unprivileged): confirms every byte matches, no password prompt.
    func checkOnly(_ request: InstallRequest) async {
        guard !busy else { return }
        banner = nil
        if customTipNeedsRestore {
            banner = Banner(
                kind: .warning,
                title: "请先恢复自定义提示状态",
                message: "检测到不完整或混合的自定义提示运行时状态。在还原对应备份前，不能检查或安装任何模式。")
            return
        }
        guard isInstallModeAvailable(request.mode) else {
            banner = Banner(
                kind: .warning,
                title: "当前模式不可用",
                message: "所选微信版本没有完整提供「\(request.mode.title)」所需的补丁能力。")
            return
        }
        busy = true
        busyMessage = "正在检查补丁点…"
        defer { busy = false; busyMessage = "" }

        let configURL = BundledPaths.effectivePatchesJSON
        let args = request.arguments(appPath: appPath, configURL: configURL, runtimeDylibURL: BundledPaths.runtimeDylib, dryRun: true)
        let result = await CLIRunner.runUser(BundledPaths.cli, args, onLine: { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        })
        if result.exitCode != 0 {
            banner = Banner(kind: .error, title: "检查未通过", message: decodeErrorMessage(from: result) ?? "补丁点检查失败。")
            return
        }
        do {
            let report = try decodeInstallReport(result.output)
            switch InstallPreflightDisposition.classify(report) {
            case .invalid:
                banner = Banner(kind: .error, title: "检查结果无效", message: "安装检查没有返回有效步骤，或包含无法安全继续的状态。请查看日志并先还原对应备份。")
            case .alreadyInstalled:
                banner = Banner(kind: .info, title: "已经安装", message: "这些补丁已经在生效中。")
            case .installable:
                banner = Banner(kind: .success, title: "检查通过", message: "现有步骤与待应用步骤兼容，可以安全安装剩余修改。")
            }
        } catch {
            banner = Banner(kind: .error, title: "检查结果不可用", message: error.localizedDescription)
        }
    }

    // MARK: - Restore

    func restore(session: BackupSession) async {
        guard !busy else { return }
        banner = nil
        if WeChatStatusProbe.isRunning(appPath: appPath) {
            banner = Banner(kind: .warning, title: "请先退出微信", message: "恢复前需要完全退出微信。")
            return
        }
        let access = Self.probeInstallAccess(appPath: appPath)
        if access == .blockedByTCC {
            banner = fullDiskAccessBanner()
            return
        }

        busy = true
        defer { busy = false; busyMessage = "" }
        busyMessage = access == .writableAsUser ? "正在恢复…" : "正在恢复（需要管理员密码）…"

        var failure: String?
        for entry in session.entries {
            let args = ["restore", "--app", appPath, "--binary", entry.binaryRelativePath, "--backup", entry.backupURL.path]
            let result: CLIResult
            if access == .writableAsUser {
                result = await CLIRunner.runUser(BundledPaths.cli, args, onLine: { [weak self] line in
                    Task { @MainActor in self?.appendLog(line) }
                })
            } else {
                result = await CLIRunner.runAdmin(BundledPaths.cli, args, operation: "restore", onLine: { [weak self] line in
                    Task { @MainActor in self?.appendLog(line) }
                })
            }
            if result.cancelled {
                banner = Banner(kind: .info, title: "已取消", message: "你取消了管理员授权。")
                return
            }
            if !result.succeeded {
                failure = friendlyFailure(result)
                break
            }
        }

        if let failure {
            banner = Banner(kind: .error, title: "恢复失败", message: failure)
        } else {
            banner = Banner(kind: .success, title: "已恢复", message: "已从备份还原。请完全退出并重新打开微信。")
            await refresh(preserveBanner: true)
        }
    }

    // MARK: - Clone (multi-instance)

    func clone(count: Int, namePrefix: String, outputDir: String, keepURLSchemes: Bool, replace: Bool) async {
        guard !busy else { return }
        banner = nil
        busy = true
        defer { busy = false; busyMessage = "" }

        func baseArgs(dryRun: Bool) -> [String] {
            var args = ["clone", "--app", appPath, "--output-dir", outputDir,
                        "--count", String(count), "--name-prefix", namePrefix, "--json"]
            if keepURLSchemes { args += ["--keep-url-schemes"] }
            if replace { args += ["--replace"] }
            if dryRun { args += ["--dry-run"] }
            return args
        }

        // 1) Dry-run to surface any planning error (e.g. target inside source bundle).
        busyMessage = "正在检查…"
        let dry = await CLIRunner.runUser(BundledPaths.cli, baseArgs(dryRun: true), onLine: { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        })
        if dry.exitCode != 0 {
            banner = Banner(kind: .error, title: "无法多开", message: decodeErrorMessage(from: dry) ?? "参数检查失败。")
            return
        }

        // 2) Write directly when the selected directory really is writable; otherwise retain
        // the administrator path required for root-owned locations such as /Applications.
        let writableAsUser = Self.canWriteCloneOutputDirectory(outputDir)
        busyMessage = writableAsUser ? "正在创建副本…" : "正在创建副本（需要管理员密码）…"
        var realArgs = baseArgs(dryRun: false)
        realArgs.removeAll { $0 == "--json" }
        let real: CLIResult
        if writableAsUser {
            real = await CLIRunner.runUser(BundledPaths.cli, realArgs, onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            })
        } else {
            real = await CLIRunner.runAdmin(BundledPaths.cli, realArgs, operation: "clone", onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            })
        }
        if real.cancelled {
            banner = Banner(kind: .info, title: "已取消", message: "你取消了管理员授权。")
        } else if real.succeeded {
            banner = Banner(kind: .success, title: "多开副本已创建",
                            message: "已在 \(outputDir) 生成 \(count) 个独立微信副本，每个需单独登录。")
        } else {
            banner = Banner(kind: .error, title: "创建失败", message: friendlyFailure(real))
        }
    }

    // MARK: - Update patch data

    func updatePatchData() async {
        guard !busy else { return }
        banner = nil
        busy = true
        busyMessage = "正在拉取最新补丁数据…"
        defer { busy = false; busyMessage = "" }
        do {
            let result = try await UpdateService.fetchLatestPatches()
            appendLog("已更新补丁数据：\(result.count) 个构建号（\(result.checksumVerified ? "校验和已验证" : "仅结构校验")）")
            await refresh()
            let verifyNote = result.checksumVerified ? "" : "（未找到校验和文件，已仅按结构校验）"
            switch supportStatus {
            case .supported:
                banner = Banner(kind: .success, title: "补丁数据已更新",
                                message: "现在已支持你的微信版本，可以开启防撤回了。\(verifyNote)")
            case .unsupported:
                banner = Banner(kind: .info, title: "补丁数据已更新",
                                message: "已拉取最新数据（\(result.count) 个构建号），但仍未包含当前微信版本 \(displayBuild)。可能上游尚未适配，请稍后再试或到项目页反馈。")
            case .noWeChat:
                banner = Banner(kind: .info, title: "补丁数据已更新",
                                message: "已拉取最新数据（\(result.count) 个构建号）。选择或安装官方微信后即可检测支持状态。")
            case .failed, .unknown:
                break
            }
        } catch {
            banner = Banner(kind: .error, title: "更新失败", message: error.localizedDescription)
        }
    }

    // MARK: - Build from source (advanced)

    @Published var toolchainAvailable: Bool = false
    @Published var usingBuiltFromSource: Bool = BundledPaths.usingBuiltFromSource

    func checkToolchain() async {
        toolchainAvailable = await SourceBuildService.toolchainAvailable()
    }

    func buildFromSource() async {
        guard !busy else { return }
        banner = nil
        busy = true
        busyMessage = "正在从源码构建…"
        defer { busy = false; busyMessage = "" }
        do {
            let outcome = try await SourceBuildService.buildFromSource(appPath: appPath, onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            })
            usingBuiltFromSource = BundledPaths.usingBuiltFromSource
            await refresh()
            guard supportStatus != .failed else { return }
            banner = Banner(kind: .success, title: "已切换到源码构建",
                            message: "已用最新源码编译的工具（commit \(outcome.commit)）。以后的操作都会用它。")
        } catch {
            usingBuiltFromSource = BundledPaths.usingBuiltFromSource
            banner = Banner(kind: .error, title: "构建失败", message: error.localizedDescription)
        }
    }

    func revertSourceBuild() async {
        do {
            try SourceBuildService.revertToBundled()
            usingBuiltFromSource = BundledPaths.usingBuiltFromSource
            await refresh()
            guard supportStatus != .failed else { return }
            banner = Banner(kind: .info, title: "已回退", message: "已改用 App 内置的工具。")
        } catch {
            usingBuiltFromSource = BundledPaths.usingBuiltFromSource
            banner = Banner(kind: .error, title: "回退失败", message: error.localizedDescription)
        }
    }

    func revertToBundledCatalog() async {
        do {
            try UpdateService.revertToBundled()
            await refresh()
            guard supportStatus != .failed else { return }
            banner = Banner(kind: .info, title: "已回退", message: "已改用 App 内置的补丁数据。")
        } catch {
            banner = Banner(kind: .error, title: "回退失败", message: error.localizedDescription)
        }
    }

    // MARK: - Logging & helpers

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    func clearLog() { logLines.removeAll() }

    private func decodeErrorMessage(from result: CLIResult) -> String? {
        guard let envelope = try? JSONDecoder().decode(
            CLIErrorEnvelope.self,
            from: Data(result.output.utf8)
        ) else {
            return nil
        }
        guard envelope.schemaVersion == GUICLIProtocol.schemaVersion else {
            return "命令行接口版本不兼容（GUI 支持 \(GUICLIProtocol.schemaVersion)，工具返回 \(envelope.schemaVersion)）。"
        }
        return envelope.error.message
    }

    private func friendlyFailure(_ result: CLIResult) -> String {
        // Look for the CLI's own hints in the log first.
        let log = result.output
        if log.contains("App Management") || log.contains("Operation not permitted") {
            return "写入被 macOS 拦截。请到「系统设置 → 隐私与安全性 → App 管理」给本 App 授权后重试（详见「权限」页）。"
        }
        if log.contains("仍在运行") || log.contains("appIsRunning") {
            return "微信仍在运行，请完全退出后重试。"
        }
        if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(log.utf8)) {
            guard envelope.schemaVersion == GUICLIProtocol.schemaVersion else {
                return "命令行接口版本不兼容（GUI 支持 \(GUICLIProtocol.schemaVersion)，工具返回 \(envelope.schemaVersion)）。"
            }
            return envelope.error.message
        }
        let tail = log.split(separator: "\n").suffix(4).joined(separator: "\n")
        return tail.isEmpty ? "操作失败（退出码 \(result.exitCode)）。可在下方日志查看详情。" : tail
    }
}

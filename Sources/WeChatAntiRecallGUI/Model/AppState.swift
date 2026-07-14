import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Target
    @Published var appPath: String = "/Applications/WeChat.app"

    // Status
    @Published var versions: VersionsReport?
    @Published var directInfo: DirectAppInfo?
    @Published var supportStatus: SupportStatus = .unknown
    @Published var installState: InstallState = .unknown
    @Published var wechatRunning: Bool = false

    // Activity
    @Published var busy: Bool = false
    @Published var busyMessage: String = ""
    @Published var banner: Banner?
    @Published var logLines: [String] = []

    private var runningPoll: Task<Void, Never>?

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
                let running = WeChatStatusProbe.isRunning()
                await MainActor.run { self?.wechatRunning = running }
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

    var effectiveCatalogSourceIsDownloaded: Bool { BundledPaths.usingDownloadedCatalog }

    // MARK: - Refresh

    func refresh() async {
        wechatRunning = WeChatStatusProbe.isRunning()

        let configURL = BundledPaths.effectivePatchesJSON
        let result = await CLIRunner.runUser(BundledPaths.cli, [
            "versions", "--app", appPath, "--config", configURL.path, "--json",
        ])

        if result.exitCode == 0, let report = try? JSONDecoder().decode(VersionsReport.self, from: Data(result.output.utf8)) {
            versions = report
            directInfo = nil
            supportStatus = report.supported ? .supported : .unsupported(build: report.app.installedBuild)
            await computeInstallState()
        } else {
            versions = nil
            // Fall back to a direct Info.plist read so we can still show something.
            if WeChatStatusProbe.appExists(at: appPath) {
                directInfo = WeChatStatusProbe.readInfo(appPath: appPath)
                supportStatus = directInfo == nil ? .noWeChat : .unsupported(build: directInfo?.installedBuild ?? "—")
            } else {
                directInfo = nil
                supportStatus = .noWeChat
            }
            installState = .unknown
        }
    }

    /// Uses an unprivileged silent dry-run to detect whether anti-recall is already applied.
    private func computeInstallState() async {
        guard case .supported = supportStatus else {
            installState = .unknown
            return
        }
        let configURL = BundledPaths.effectivePatchesJSON
        let args = InstallRequest(mode: .silent).arguments(
            appPath: appPath, configURL: configURL, runtimeDylibURL: BundledPaths.runtimeDylib, dryRun: true)
        let result = await CLIRunner.runUser(BundledPaths.cli, args)

        guard result.exitCode == 0,
              let report = try? JSONDecoder().decode(InstallReport.self, from: Data(result.output.utf8)) else {
            installState = .unknown
            return
        }
        if !report.allEntriesClean {
            installState = .mismatch
        } else if report.alreadyApplied {
            installState = .installed
        } else {
            installState = .notInstalled
        }
    }

    // MARK: - Quit WeChat

    func quitWeChat() async {
        busy = true
        busyMessage = "正在退出微信…"
        await WeChatStatusProbe.quitAll()
        wechatRunning = WeChatStatusProbe.isRunning()
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

    /// The one-click flow: verify WeChat is quit, dry-run to confirm every byte matches,
    /// then elevate for the real install. Any byte mismatch aborts before touching the app.
    func install(_ request: InstallRequest) async {
        guard !busy else { return }
        banner = nil
        appendLog("——— 开始：\(request.mode.title) ———")

        if WeChatStatusProbe.isRunning() {
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
        if let report = try? JSONDecoder().decode(InstallReport.self, from: Data(dry.output.utf8)) {
            if !report.allEntriesClean {
                banner = Banner(kind: .error, title: "补丁点不匹配", message: "当前微信的字节与补丁不符，可能版本数据过旧。请到「更新」页拉取最新补丁数据后重试。")
                return
            }
            if report.alreadyApplied && request.mode == .silent {
                banner = Banner(kind: .info, title: "已经开启", message: "防撤回已经在生效中，无需重复安装。")
                installState = .installed
                return
            }
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
            await refresh()
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
        if let report = try? JSONDecoder().decode(InstallReport.self, from: Data(result.output.utf8)) {
            if !report.allEntriesClean {
                banner = Banner(kind: .error, title: "补丁点不匹配", message: "字节与补丁不符，请先到「检查更新」拉取最新补丁数据。")
            } else if report.alreadyApplied {
                banner = Banner(kind: .info, title: "已经安装", message: "这些补丁已经在生效中。")
            } else {
                banner = Banner(kind: .success, title: "检查通过", message: "所有补丁点匹配，可以安全安装。")
            }
        }
    }

    // MARK: - Restore

    func restore(session: BackupSession) async {
        guard !busy else { return }
        banner = nil
        if WeChatStatusProbe.isRunning() {
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
            await refresh()
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

        // 2) Real clone (elevated — writes to /Applications).
        busyMessage = "正在创建副本（需要管理员密码）…"
        var realArgs = baseArgs(dryRun: false)
        realArgs.removeAll { $0 == "--json" }
        let real = await CLIRunner.runAdmin(BundledPaths.cli, realArgs, operation: "clone", onLine: { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        })
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
            if case .supported = supportStatus {
                banner = Banner(kind: .success, title: "补丁数据已更新",
                                message: "现在已支持你的微信版本，可以开启防撤回了。\(verifyNote)")
            } else {
                banner = Banner(kind: .info, title: "补丁数据已更新",
                                message: "已拉取最新数据（\(result.count) 个构建号），但仍未包含当前微信版本 \(displayBuild)。可能上游尚未适配，请稍后再试或到项目页反馈。")
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
            let outcome = try await SourceBuildService.buildFromSource(onLine: { [weak self] line in
                Task { @MainActor in self?.appendLog(line) }
            })
            usingBuiltFromSource = true
            await refresh()
            banner = Banner(kind: .success, title: "已切换到源码构建",
                            message: "已用最新源码编译的工具（commit \(outcome.commit)）。以后的操作都会用它。")
        } catch {
            banner = Banner(kind: .error, title: "构建失败", message: error.localizedDescription)
        }
    }

    func revertSourceBuild() async {
        do {
            try SourceBuildService.revertToBundled()
            usingBuiltFromSource = false
            await refresh()
            banner = Banner(kind: .info, title: "已回退", message: "已改用 App 内置的工具。")
        } catch {
            banner = Banner(kind: .error, title: "回退失败", message: error.localizedDescription)
        }
    }

    func revertToBundledCatalog() async {
        do {
            try UpdateService.revertToBundled()
            await refresh()
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
        if let env = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
            return env.error.message
        }
        return nil
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
        if let env = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(log.utf8)) {
            return env.error.message
        }
        let tail = log.split(separator: "\n").suffix(4).joined(separator: "\n")
        return tail.isEmpty ? "操作失败（退出码 \(result.exitCode)）。可在下方日志查看详情。" : tail
    }
}

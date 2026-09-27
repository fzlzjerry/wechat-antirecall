import Foundation

// Manages the custom recall-tip phrase. All operations run at the user's own privilege
// (never elevated) because the phrase is stored in the user's WeChat preferences domain.
@MainActor
final class TipPhraseController: ObservableObject {
    @Published var phrase: String = ""
    @Published var preview: String = ""
    @Published var probeEnabled: Bool = false
    @Published var busy: Bool = false
    @Published var validationError: String?
    @Published var saveMessage: String?
    @Published var loadError: String?

    private var targetRevision: UInt64 = 0
    private var activeAppPath: String?
    private var previewRevision: UInt64 = 0

    static let maxLength = 120
    static let defaultPhrase = "已拦截一条撤回消息"

    // MARK: - Validation (mirrors RecallTipPhrase in the CLI)

    func validate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "短语不能为空。" }
        if trimmed.contains(where: \.isNewline) { return "短语不能包含换行。" }
        if trimmed.contains("]]>") { return "短语不能包含 ]]> 标记。" }
        if trimmed.count > Self.maxLength { return "短语最长 \(Self.maxLength) 个字符。" }
        return nil
    }

    // MARK: - Load / Save

    func load(appPath: String) async {
        let revision = beginTargetOperation(appPath: appPath)
        busy = true
        validationError = nil
        saveMessage = nil
        loadError = nil

        let get = await CLIRunner.runUser(
            BundledPaths.cli,
            targetedArguments(["get"], appPath: appPath))
        guard targetOperationIsCurrent(revision, appPath: appPath) else { return }
        if get.succeeded,
           let line = get.output.split(separator: "\n").first(where: { $0.hasPrefix("Phrase: ") }) {
            phrase = String(line.dropFirst("Phrase: ".count))
        } else {
            // Never leave the editor as a misleading empty 0/120 field. App Data Protection can
            // deny a newly signed GUI access to WeChat's container until Full Disk Access is
            // granted; the default remains editable while the UI explains how to restore access.
            phrase = Self.defaultPhrase
            loadError = accessAwareMessage(
                result: get,
                fallback: "未能读取已保存的短语，当前先显示默认值。")
        }

        let probe = await CLIRunner.runUser(
            BundledPaths.cli,
            targetedArguments(["probe", "get"], appPath: appPath))
        guard targetOperationIsCurrent(revision, appPath: appPath) else { return }
        probeEnabled = probe.succeeded && probe.output.contains("enabled")
        busy = false
        await refreshPreview()
    }

    @discardableResult
    func save(appPath: String) async -> Bool {
        validationError = validate(phrase)
        guard validationError == nil else { return false }
        let revision = beginTargetOperation(appPath: appPath)
        busy = true
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await CLIRunner.runUser(
            BundledPaths.cli,
            targetedArguments(["set", trimmed], appPath: appPath))
        guard targetOperationIsCurrent(revision, appPath: appPath) else { return false }
        busy = false
        if result.succeeded {
            loadError = nil
            saveMessage = "已保存。改完请完全退出并重开微信。"
            await refreshPreview()
            return true
        } else {
            validationError = accessAwareMessage(result: result, fallback: "保存失败。")
            return false
        }
    }

    func reset(appPath: String) async {
        let revision = beginTargetOperation(appPath: appPath)
        busy = true
        let result = await CLIRunner.runUser(
            BundledPaths.cli,
            targetedArguments(["reset"], appPath: appPath))
        guard targetOperationIsCurrent(revision, appPath: appPath) else { return }
        if result.succeeded {
            await load(appPath: appPath)
            guard activeAppPath == appPath else { return }
            saveMessage = "已恢复默认短语。"
        } else {
            busy = false
            validationError = accessAwareMessage(result: result, fallback: "恢复默认短语失败。")
        }
    }

    // MARK: - Preview (debounced by the view)

    func refreshPreview() async {
        previewRevision &+= 1
        let revision = previewRevision
        let candidate = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(candidate) == nil else { preview = ""; return }
        let result = await CLIRunner.runUser(
            BundledPaths.cli,
            ["tip-phrase", "preview", candidate, "--from", "张三", "--message", "这是一条示例消息"]
        )
        guard revision == previewRevision else { return }
        // Output: "Preview:\n<rendered>"
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let idx = lines.firstIndex(where: { $0.hasPrefix("Preview:") }), idx + 1 < lines.count {
            preview = lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            preview = ""
        }
    }

    // MARK: - Debug probe

    func setProbe(_ enabled: Bool, appPath: String) async {
        let revision = beginTargetOperation(appPath: appPath)
        busy = true
        let result = await CLIRunner.runUser(
            BundledPaths.cli,
            targetedArguments(["probe", enabled ? "on" : "off"], appPath: appPath))
        guard targetOperationIsCurrent(revision, appPath: appPath) else { return }
        busy = false
        if result.succeeded {
            probeEnabled = enabled
        } else {
            validationError = accessAwareMessage(result: result, fallback: "更新调试探针失败。")
        }
    }

    private func beginTargetOperation(appPath: String) -> UInt64 {
        targetRevision &+= 1
        previewRevision &+= 1
        activeAppPath = appPath
        return targetRevision
    }

    private func targetOperationIsCurrent(_ revision: UInt64, appPath: String) -> Bool {
        targetRevision == revision && activeAppPath == appPath
    }

    private func targetedArguments(_ arguments: [String], appPath: String) -> [String] {
        ["tip-phrase"] + arguments + ["--app", appPath]
    }

    private func decodeError(_ result: CLIResult) -> String? {
        let text = (result.stderr + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func accessAwareMessage(result: CLIResult, fallback: String) -> String {
        let detail = decodeError(result) ?? ""
        let lowered = detail.lowercased()
        if lowered.contains("operation not permitted")
            || lowered.contains("permission denied")
            || lowered.contains("permission")
            || lowered.contains("not authorized") {
            return "macOS 阻止了对微信数据目录的访问。请为本 App 开启「完全磁盘访问」，然后退出并重新打开本 App。"
        }
        return detail.isEmpty ? fallback : "\(fallback) \(detail)"
    }
}

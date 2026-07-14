import Foundation

// Manages the custom recall-tip phrase. All operations run at the user's own privilege
// (never elevated) because the phrase lives in the per-user WeChat container plist.
@MainActor
final class TipPhraseController: ObservableObject {
    @Published var phrase: String = ""
    @Published var preview: String = ""
    @Published var probeEnabled: Bool = false
    @Published var busy: Bool = false
    @Published var validationError: String?
    @Published var saveMessage: String?

    static let maxLength = 120

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

    func load() async {
        busy = true; defer { busy = false }
        let get = await CLIRunner.runUser(BundledPaths.cli, ["tip-phrase", "get"])
        if let line = get.output.split(separator: "\n").first(where: { $0.hasPrefix("Phrase: ") }) {
            phrase = String(line.dropFirst("Phrase: ".count))
        }
        let probe = await CLIRunner.runUser(BundledPaths.cli, ["tip-phrase", "probe", "get"])
        probeEnabled = probe.output.contains("enabled")
        await refreshPreview()
    }

    func save() async {
        validationError = validate(phrase)
        guard validationError == nil else { return }
        busy = true; defer { busy = false }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await CLIRunner.runUser(BundledPaths.cli, ["tip-phrase", "set", trimmed])
        if result.succeeded {
            saveMessage = "已保存。改完请完全退出并重开微信。"
            await refreshPreview()
        } else {
            validationError = decodeError(result) ?? "保存失败。"
        }
    }

    func reset() async {
        busy = true; defer { busy = false }
        let result = await CLIRunner.runUser(BundledPaths.cli, ["tip-phrase", "reset"])
        if result.succeeded {
            phrase = ""
            saveMessage = "已恢复默认短语。"
            await load()
        }
    }

    // MARK: - Preview (debounced by the view)

    func refreshPreview() async {
        let candidate = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validate(candidate) == nil else { preview = ""; return }
        let result = await CLIRunner.runUser(
            BundledPaths.cli,
            ["tip-phrase", "preview", candidate, "--from", "张三", "--message", "这是一条示例消息"]
        )
        // Output: "Preview:\n<rendered>"
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let idx = lines.firstIndex(where: { $0.hasPrefix("Preview:") }), idx + 1 < lines.count {
            preview = lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            preview = ""
        }
    }

    // MARK: - Debug probe

    func setProbe(_ enabled: Bool) async {
        busy = true; defer { busy = false }
        let result = await CLIRunner.runUser(BundledPaths.cli, ["tip-phrase", "probe", enabled ? "on" : "off"])
        if result.succeeded { probeEnabled = enabled }
    }

    private func decodeError(_ result: CLIResult) -> String? {
        let text = (result.stderr + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

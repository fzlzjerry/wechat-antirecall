import Foundation

@MainActor
final class RedPacketController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case off
        case grab
        case notifyOnly
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "关闭"
            case .grab: return "自动领取"
            case .notifyOnly: return "仅提醒"
            }
        }
    }

    @Published private(set) var mode: Mode = .off
    @Published var delayMilliseconds = 500
    @Published private(set) var supported = false
    @Published private(set) var runtimeAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private var revision: UInt64 = 0

    struct Report: Decodable {
        struct Settings: Decodable {
            let enabled: Bool
            let delayMilliseconds: Int
            let notifyOnly: Bool

            // A Decodable-only type with a custom init(from:) gets no synthesized
            // CodingKeys, so they must be declared explicitly.
            private enum CodingKeys: String, CodingKey {
                case enabled, delayMilliseconds, notifyOnly
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // Older CLI builds predate notifyOnly; default to the legacy mode.
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                delayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .delayMilliseconds) ?? 500
                notifyOnly = try container.decodeIfPresent(Bool.self, forKey: .notifyOnly) ?? false
            }
        }
        let schemaVersion: Int
        let settings: Settings
        let supported: Bool
        let build: String
        let runtimeAvailable: Bool
    }

    func load(appPath: String) async { await run(["get"], appPath: appPath, saving: false, requestedMode: nil) }

    func setMode(_ newMode: Mode, appPath: String) async {
        var arguments: [String]
        switch newMode {
        case .off:
            arguments = ["off"]
        case .grab:
            arguments = ["on", "--delay-ms", String(delayMilliseconds)]
        case .notifyOnly:
            arguments = ["on", "--notify-only"]
        }
        await run(arguments, appPath: appPath, saving: true, requestedMode: newMode)
    }

    private func run(_ arguments: [String], appPath: String, saving: Bool, requestedMode: Mode?) async {
        revision &+= 1
        let activeRevision = revision
        busy = true
        error = nil
        message = nil
        if !saving { mode = .off; supported = false; runtimeAvailable = false }
        let result = await CLIRunner.runUser(
            BundledPaths.cli, ["red-packet"] + arguments + ["--app", appPath, "--json"])
        guard revision == activeRevision else { return }
        busy = false
        if result.succeeded,
           let report = try? JSONDecoder().decode(Report.self, from: Data(result.output.utf8)),
           report.schemaVersion == GUICLIProtocol.schemaVersion {
            mode = !report.settings.enabled ? .off : (report.settings.notifyOnly ? .notifyOnly : .grab)
            delayMilliseconds = report.settings.delayMilliseconds
            supported = report.supported
            runtimeAvailable = report.runtimeAvailable
            if saving {
                switch requestedMode {
                case .off:
                    message = "已关闭自动红包。"
                case .grab:
                    message = "已保存。新安装或更新组件后，请完全退出并重新打开微信。"
                case .notifyOnly:
                    message = "已保存。收到红包（包括静默群）将弹系统通知，不会自动领取。"
                case nil:
                    message = nil
                }
            }
        } else {
            let failureText = (result.output + result.stderr).lowercased()
            if failureText.contains("permission") || failureText.contains("not permitted") || failureText.contains("权限") {
                error = "无法读取微信设置。请为本工具开启「完全磁盘访问权限」，退出并重新打开后重试。"
            } else if let envelope = try? JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(result.output.utf8)) {
                error = envelope.error.message
            } else {
                error = "无法读取或保存红包设置。请重新读取后重试。"
            }
        }
    }
}

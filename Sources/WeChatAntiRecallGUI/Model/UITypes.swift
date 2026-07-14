import Foundation

struct GUIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum InstallMode: String, CaseIterable, Identifiable {
    case silent
    case customTip
    case updateOnly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .silent: return "静默防撤回"
        case .customTip: return "自定义撤回提示"
        case .updateOnly: return "仅屏蔽自动更新"
        }
    }

    var subtitle: String {
        switch self {
        case .silent: return "别人撤回的消息原样留下，不显示任何提示"
        case .customTip: return "把别人撤回的提示换成你的自定义短语（需该版本支持）"
        case .updateOnly: return "只拦截微信自动升级，不改动防撤回"
        }
    }
}

/// Builds the CLI argument list for an install. The GUI always passes absolute
/// `--config` / `--runtime-dylib` because a launched .app's working directory is `/`.
struct InstallRequest {
    var mode: InstallMode = .silent
    var blockUpdate = false
    var multiInstance = false

    func arguments(appPath: String, configURL: URL, runtimeDylibURL: URL, dryRun: Bool) -> [String] {
        var args = ["install", "--app", appPath, "--config", configURL.path, "--json"]
        switch mode {
        case .silent:
            break
        case .customTip:
            args += ["--runtime-tip", "--runtime-dylib", runtimeDylibURL.path]
        case .updateOnly:
            args += ["--update-only"]
        }
        if blockUpdate && mode != .updateOnly {
            args += ["--block-update"]
        }
        if multiInstance && mode != .updateOnly {
            args += ["--multi-instance"]
        }
        if dryRun {
            args += ["--dry-run"]
        }
        return args
    }
}

enum SupportStatus: Equatable {
    case supported
    case unsupported(build: String)
    case noWeChat
    case unknown
}

/// Whether the default silent anti-recall is currently applied to WeChat.
enum InstallState: Equatable {
    case notInstalled
    case installed
    case mismatch
    case unknown
}

enum BannerKind {
    case success
    case error
    case info
    case warning
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let kind: BannerKind
    let title: String
    let message: String
    /// Optional System Settings deep link; when set, the banner shows a one-click button.
    var settingsURL: String? = nil
    var settingsButtonTitle: String = "打开系统设置"

    static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
}

import SwiftUI
import AppKit

struct PermissionsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("权限与帮助").font(.title2.weight(.semibold))

            permissionCard(
                icon: "app.badge.checkmark",
                title: "App 管理",
                body: "打补丁需要修改「应用程序」里的微信。如果安装时报「Operation not permitted」，请在这里给本 App 授权。",
                buttonTitle: "打开 App 管理设置",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
            )

            permissionCard(
                icon: "externaldrive.badge.person.crop",
                title: "完全磁盘访问",
                body: "打补丁会用 ad-hoc 重新签名微信，抹掉原有签名身份。新版 macOS（26/27）可能因此拒绝微信访问它的数据目录，导致打补丁后微信打不开。给微信本身授予「完全磁盘访问」即可解决。\n注意：每次重新打补丁或微信升级后，签名会变，可能需要在列表里删掉旧的微信重新添加。",
                buttonTitle: "打开完全磁盘访问设置",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            )

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").foregroundStyle(Theme.accent)
                        SectionLabel(text: "无需关闭 SIP")
                    }
                    Text("本工具只修改「应用程序」里的第三方微信，不碰系统保护区域，因此不需要关闭系统完整性保护（SIP）。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "testtube.2").foregroundStyle(.orange)
                        SectionLabel(text: "安装后请做一次实测")
                    }
                    Text("补丁点检查通过，并不能证明防撤回在真实撤回时一定生效。第一次在某个版本上使用时，建议用另一台设备或账号发一条消息再撤回，确认原消息是否留存。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func permissionCard(icon: String, title: String, body text: String, buttonTitle: String, url: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(Theme.accent)
                    SectionLabel(text: title)
                }
                Text(text)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                } label: {
                    Label(buttonTitle, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

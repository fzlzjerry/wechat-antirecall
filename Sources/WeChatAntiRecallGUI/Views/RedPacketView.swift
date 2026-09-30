import SwiftUI
import AppKit

struct RedPacketView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = RedPacketController()

    private var runtimeInstalled: Bool {
        controller.runtimeAvailable && state.installedMode == .customTip && state.installState == .installed
    }

    private var modeDescription: String {
        switch controller.mode {
        case .off:
            return "开启后处理新收到的普通红包。每个红包只处理一次，跳过历史消息、自己发送和已经领取的红包。"
        case .grab:
            return "自动接收并拆开新收到的普通红包，跳过历史消息、自己发送和已经领取的红包。每个红包只尝试一次。"
        case .notifyOnly:
            return "收到红包时弹 macOS 系统通知提醒（包括已静默的群聊），不会自动领取。点击通知可打开微信，每个红包只提醒一次。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            HStack {
                Text("红包助手").font(.title2.weight(.semibold))
                StatusPill(tone: .neutral,
                           text: controller.supported ? "已适配" : "待适配",
                           systemImage: controller.supported ? "checkmark.circle" : "info.circle")
            }
            Text(modeDescription)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = state.banner { BannerView(banner: banner) }
            if let error = controller.error {
                HintRow(systemImage: "exclamationmark.circle", text: error, tint: .orange)
                Button("重新读取设置") { Task { await controller.load(appPath: state.appPath) } }
                    .disabled(controller.busy)
                Button("打开完全磁盘访问设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "当前支持")
                    Text("微信 4.1.13（269624 / 269628）及 4.1.15（270090 / 270100 / 270102 / 270132）")
                    Text("用户已在微信 4.1.15.10（270090）实测确认普通红包自动领取可用。270100、270102、270132 已完成静态地址核对，领取结果仍以微信显示为准。")
                        .font(.callout).foregroundStyle(.secondary)
                    if controller.supported && !runtimeInstalled {
                        Text("需要更新本工具的运行组件，并使用自定义撤回提示模式。安装前请完全退出微信。")
                            .font(.callout).foregroundStyle(.secondary)
                        Button(controller.runtimeAvailable ? "安装运行组件" : "安装或更新运行组件") {
                            Task {
                                await state.install(InstallRequest(mode: .customTip), refreshRuntime: true)
                                await controller.load(appPath: state.appPath)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.busy || controller.busy || state.wechatRunning || !state.customTipAvailable)
                        if state.wechatRunning {
                            Button("退出微信") { Task { await state.quitWeChat() } }.disabled(state.busy)
                        }
                    } else if !controller.supported && !controller.busy && controller.error == nil {
                        Text("当前所选构建尚未适配，无法开启红包功能。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(text: "工作模式")
                    Picker("红包模式", selection: Binding(
                        get: { controller.mode },
                        set: { newMode in
                            // Without the runtime component only turning off is
                            // reachable, mirroring the original toggle semantics.
                            guard newMode == .off || (runtimeInstalled && controller.supported) else { return }
                            Task { await controller.setMode(newMode, appPath: state.appPath) }
                        }
                    )) {
                        ForEach(RedPacketController.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(controller.busy || state.busy ||
                        (controller.mode == .off && (!runtimeInstalled || !controller.supported)))
                    if controller.mode == .grab {
                        Stepper("收到后等待 \(controller.delayMilliseconds) 毫秒", value: $controller.delayMilliseconds, in: 0...5000, step: 100)
                            .disabled(controller.busy || state.busy)
                        Button("保存等待时间") { Task { await controller.setMode(.grab, appPath: state.appPath) } }
                            .disabled(controller.busy || state.busy)
                    }
                    if let message = controller.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: state.appPath) { await controller.load(appPath: state.appPath) }
    }
}

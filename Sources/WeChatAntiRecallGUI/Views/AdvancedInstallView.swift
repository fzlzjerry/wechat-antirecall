import SwiftUI

struct AdvancedInstallView: View {
    @EnvironmentObject var state: AppState

    @State private var mode: InstallMode = .silent
    @State private var blockUpdate = false
    @State private var multiInstance = false

    private var request: InstallRequest {
        InstallRequest(mode: mode, blockUpdate: blockUpdate, multiInstance: multiInstance)
    }

    private var features: VersionsReport.Features? { state.versions?.features }
    private var supported: Bool { if case .supported = state.supportStatus { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("高级安装").font(.title2.weight(.semibold))

            if let banner = state.banner { BannerView(banner: banner) }

            if !supported {
                Card {
                    HintRow(systemImage: "info.circle",
                            text: "请先在「首页」确认当前微信版本受支持。不支持时可到「检查更新」拉取最新补丁数据。")
                }
            }

            modeCard
            optionsCard
            actionCard
        }
        .onChange(of: mode) { newMode in
            if newMode == .updateOnly { blockUpdate = false; multiInstance = false }
        }
    }

    private var modeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "模式")
                ForEach(InstallMode.allCases) { m in
                    let disabled = (m == .customTip && !state.runtimeTipSupported)
                    Button {
                        if !disabled { mode = m }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(mode == m ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).foregroundStyle(disabled ? .secondary : .primary)
                                Text(disabled ? "当前版本不支持自定义提示（需要新的应用更新，不是拉数据能解决）" : m.subtitle)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
                if mode == .customTip {
                    HintRow(systemImage: "text.bubble",
                            text: "自定义短语在「自定义提示」页设置；这里负责安装运行时 hook。")
                }
            }
        }
    }

    private var optionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "附加选项")
                Toggle(isOn: $blockUpdate) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("同时屏蔽自动更新")
                        Text(canBlockUpdate ? "拦住微信自动升级，避免升级还原补丁" : "当前版本没有可用的屏蔽更新补丁点")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(mode == .updateOnly || !canBlockUpdate)
                .tint(Theme.accent)

                Toggle(isOn: $multiInstance) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("历史多开补丁")
                        Text(canMultiInstance ? "仅个别版本支持；一般多开请用「微信多开」页" : "当前版本不支持历史多开补丁，请用「微信多开」页")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(mode == .updateOnly || !canMultiInstance)
                .tint(Theme.accent)
            }
        }
    }

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if state.wechatRunning {
                    HStack {
                        HintRow(systemImage: "exclamationmark.circle.fill", text: "安装前请先退出微信。", tint: .orange)
                        Button("退出微信") { Task { await state.quitWeChat() } }.disabled(state.busy)
                    }
                }
                HStack {
                    Button("试运行（不改动）") { Task { await state.checkOnly(request) } }
                        .buttonStyle(.bordered)
                        .disabled(state.busy || !supported)
                    Button {
                        Task { await state.install(request) }
                    } label: {
                        Text("安装").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(state.busy || !supported || state.wechatRunning)
                    if state.busy {
                        ProgressView().controlSize(.small)
                        Text(state.busyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HintRow(systemImage: "info.circle", text: "安装会重新签名微信并弹出一次管理员密码。装完请完全退出并重开微信，并做一次撤回实测。")
            }
        }
    }

    private var canBlockUpdate: Bool { features?.blockUpdate ?? false }
    private var canMultiInstance: Bool { features?.multiInstance ?? false }
}

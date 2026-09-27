import SwiftUI

struct AdvancedInstallView: View {
    @EnvironmentObject var state: AppState

    @Binding var mode: InstallMode
    @Binding var blockUpdate: Bool
    @Binding var multiInstance: Bool
    var goToRestore: () -> Void

    private var request: InstallRequest {
        InstallRequest(
            mode: mode,
            blockUpdate: mode != .updateOnly && blockUpdate && canBlockUpdate,
            multiInstance: mode != .updateOnly && multiInstance && canMultiInstance)
    }

    private var features: VersionsReport.Features? { state.versions?.features }
    private var supported: Bool { if case .supported = state.supportStatus { return true } else { return false } }
    private var modeAvailable: Bool { state.isInstallModeAvailable(mode) }
    private var requiresRestore: Bool {
        state.customTipNeedsRestore
            || (state.installedMode == .customTip && mode == .silent)
    }

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
                    let disabled = !state.isInstallModeAvailable(m)
                    Button {
                        if !disabled { mode = m }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(mode == m ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Text(m.title).foregroundStyle(disabled ? .secondary : .primary)
                                    if state.installedMode == m {
                                        StatusPill(tone: .good, text: "当前模式", systemImage: "checkmark.circle.fill")
                                    }
                                    if m == .updateOnly {
                                        updateBlockStatusPill
                                    }
                                }
                                Text(disabled ? unavailableReason(for: m) : m.subtitle)
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
                            text: "自定义短语可在「自定义提示」页直接保存并安装；这里用于组合更多高级选项。")
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
                if requiresRestore {
                    HStack(alignment: .top) {
                        HintRow(
                            systemImage: "arrow.uturn.backward.circle.fill",
                            text: restoreRequirementText,
                            tint: .orange)
                        Button("前往恢复") { goToRestore() }
                            .buttonStyle(.bordered)
                    }
                }
                if state.wechatRunning {
                    HStack {
                        HintRow(systemImage: "exclamationmark.circle.fill", text: "安装前请先退出微信。", tint: .orange)
                        Button("退出微信") { Task { await state.quitWeChat() } }.disabled(state.busy)
                    }
                }
                HStack {
                    Button("试运行（不改动）") { Task { await state.checkOnly(request) } }
                        .buttonStyle(.bordered)
                        .disabled(state.busy || !supported || !modeAvailable || requiresRestore)
                    Button {
                        Task { await state.install(request) }
                    } label: {
                        Text("安装").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(state.busy || !supported || !modeAvailable || requiresRestore || state.wechatRunning)
                    if state.busy {
                        ProgressView().controlSize(.small)
                        Text(state.busyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HintRow(systemImage: "info.circle", text: "安装会重新签名微信；仅当所选 App 无法直接写入时才会请求管理员密码。装完请完全退出并重开微信，并做一次撤回实测。")
            }
        }
    }

    private var canBlockUpdate: Bool { state.updateOnlyAvailable }
    private var canMultiInstance: Bool { features?.multiInstance ?? false }

    private func unavailableReason(for candidate: InstallMode) -> String {
        switch candidate {
        case .customTip:
            if state.customTipRuntimeOutdated {
                return "最新补丁已支持；请更新本应用，或在「检查更新」中从最新源码构建运行组件"
            }
            return "当前版本未同时提供自定义提示所需的运行时和提示补丁"
        case .updateOnly:
            return "当前版本没有可用的屏蔽更新补丁点"
        case .silent:
            return "当前版本没有可用的静默防撤回补丁点"
        }
    }

    private var restoreRequirementText: String {
        if state.customTipNeedsRestore {
            return "检测到不完整或混合的自定义提示状态。还原对应备份前不能检查或安装任何模式。"
        }
        return "从「自定义提示」切回「静默防撤回」前，需先还原备份，避免留下运行时 hook。"
    }

    private var updateBlockStatusPill: some View {
        if !canBlockUpdate {
            return AnyView(StatusPill(tone: .neutral, text: "当前版本不可用"))
        }
        switch state.updateBlockState {
        case .installed:
            return AnyView(StatusPill(tone: .good, text: "已安装", systemImage: "checkmark.circle.fill"))
        case .notInstalled:
            return AnyView(StatusPill(tone: .neutral, text: "未安装"))
        case .mismatch:
            return AnyView(StatusPill(tone: .warn, text: "状态异常", systemImage: "exclamationmark.triangle.fill"))
        case .unknown:
            return AnyView(StatusPill(tone: .neutral, text: "状态未知"))
        }
    }
}

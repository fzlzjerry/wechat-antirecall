import SwiftUI
import AppKit

struct TipPhraseView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = TipPhraseController()
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("自定义提示").font(.title2.weight(.semibold))

            if let banner = state.banner {
                BannerView(banner: banner)
            }

            if !state.runtimeTipSupported {
                Card {
                    HintRow(systemImage: "exclamationmark.triangle",
                            text: "当前微信版本不支持自定义提示（需要新的应用更新）。你仍可编辑短语，但要在支持的版本上安装「自定义提示」模式后才会生效。",
                            tint: .orange)
                }
            }

            if let loadError = controller.loadError {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HintRow(
                            systemImage: "lock.trianglebadge.exclamationmark",
                            text: loadError,
                            tint: .orange)
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("打开完全磁盘访问设置", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            editorCard
            previewCard
            installCard
            probeCard
        }
        .onAppear { Task { await controller.load() } }
    }

    private var editorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(text: "撤回提示短语")
                    Spacer()
                    Text("\(controller.phrase.count)/\(TipPhraseController.maxLength)")
                        .font(.caption.monospaced())
                        .foregroundStyle(controller.phrase.count > TipPhraseController.maxLength ? .red : .secondary)
                }
                Text("把别人撤回消息时显示的提示换成你的短语。你自己的撤回不受影响。")
                    .font(.callout).foregroundStyle(.secondary)

                TextField("例如：已拦截 {from} 于 {time} 撤回的一条消息", text: $controller.phrase)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: controller.phrase) { _ in scheduledPreview() }

                HStack(spacing: 8) {
                    placeholderChip("{from}", "发送者", enabled: true)
                    placeholderChip("{time}", "时间", enabled: true)
                    placeholderChip("{content}", "内容·269340/269341", enabled: true)
                }

                if let err = controller.validationError {
                    HintRow(systemImage: "exclamationmark.circle", text: err, tint: .red)
                }
                if let msg = controller.saveMessage {
                    HintRow(systemImage: "checkmark.circle", text: msg, tint: Theme.accent)
                }

                HStack {
                    Button("仅保存") { Task { await controller.save() } }
                        .buttonStyle(.bordered)
                        .disabled(controller.busy)
                    Button("恢复默认") { Task { await controller.reset() } }
                        .buttonStyle(.bordered)
                        .disabled(controller.busy)
                    if controller.busy { ProgressView().controlSize(.small) }
                }
                HintRow(systemImage: "info.circle",
                        text: customTipInstalled
                            ? "运行时已安装；保存后完全退出并重开微信即可生效。"
                            : "可在下方一次完成「保存短语 + 安装运行时」，无需再跳到高级安装。")
            }
        }
    }

    private var previewCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "预览")
                Text(controller.preview.isEmpty ? "（输入短语后显示预览）" : controller.preview)
                    .font(.callout)
                    .foregroundStyle(controller.preview.isEmpty ? .secondary : .primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Text("说明：构建号 269340、269341 会显示本次启动后缓存的文字或媒体类型；其他构建、冷缓存、已淘汰或 ID 缺失的消息会省略。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: customTipInstalled ? "应用修改" : "保存并开启")
                    Spacer()
                    StatusPill(
                        tone: customTipInstalled ? .good : .neutral,
                        text: customTipInstalled ? "已安装" : "未安装",
                        systemImage: customTipInstalled ? "checkmark.circle.fill" : "circle")
                }

                Text(customTipInstalled
                     ? "当前已是自定义提示模式。保存新短语后，只需重启微信，不会重复修改或签名 App。"
                     : "会先校验并保存短语，再检查补丁点、安装自定义提示运行时并重新签名微信。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.wechatRunning && !customTipInstalled {
                    HStack {
                        HintRow(systemImage: "exclamationmark.circle.fill", text: "首次安装前请先完全退出微信。", tint: .orange)
                        Button("退出微信") { Task { await state.quitWeChat() } }
                            .disabled(state.busy)
                    }
                }

                Button {
                    Task { await saveAndApply() }
                } label: {
                    Text(customTipInstalled ? "保存并应用" : "保存并开启自定义提示")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .disabled(controller.busy || state.busy || !state.runtimeTipSupported || (state.wechatRunning && !customTipInstalled))
            }
        }
    }

    private var probeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { controller.probeEnabled },
                    set: { newValue in Task { await controller.setProbe(newValue) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("调试探针")
                        Text("把撤回的 XML 和元数据写入 macOS 控制台，仅在排查问题时开启，用完请关闭。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                .disabled(controller.busy)
            }
        }
    }

    private func placeholderChip(_ token: String, _ label: String, enabled: Bool) -> some View {
        Button {
            if enabled { controller.phrase += token; scheduledPreview() }
        } label: {
            VStack(spacing: 1) {
                Text(token).font(.caption.monospaced().weight(.medium))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(enabled ? 0.06 : 0.03)))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func scheduledPreview() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { await controller.refreshPreview() }
        }
    }

    private var customTipInstalled: Bool {
        state.installState == .installed && state.installedMode == .customTip
    }

    private func saveAndApply() async {
        guard await controller.save() else { return }
        if customTipInstalled {
            state.banner = Banner(
                kind: .success,
                title: "自定义提示已保存",
                message: "请完全退出并重开微信，新短语即可生效。")
        } else {
            await state.install(InstallRequest(mode: .customTip))
        }
    }
}

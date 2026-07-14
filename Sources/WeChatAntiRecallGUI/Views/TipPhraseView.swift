import SwiftUI

struct TipPhraseView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var controller = TipPhraseController()
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("自定义提示").font(.title2.weight(.semibold))

            if !state.runtimeTipSupported {
                Card {
                    HintRow(systemImage: "exclamationmark.triangle",
                            text: "当前微信版本不支持自定义提示（需要新的应用更新）。你仍可编辑短语，但要在支持的版本上安装「自定义提示」模式后才会生效。",
                            tint: .orange)
                }
            }

            editorCard
            previewCard
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
                    placeholderChip("{content}", "内容·暂不可用", enabled: false)
                }

                if let err = controller.validationError {
                    HintRow(systemImage: "exclamationmark.circle", text: err, tint: .red)
                }
                if let msg = controller.saveMessage {
                    HintRow(systemImage: "checkmark.circle", text: msg, tint: Theme.accent)
                }

                HStack {
                    Button("保存") { Task { await controller.save() } }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(controller.busy)
                    Button("恢复默认") { Task { await controller.reset() } }
                        .buttonStyle(.bordered)
                        .disabled(controller.busy)
                    if controller.busy { ProgressView().controlSize(.small) }
                }
                HintRow(systemImage: "info.circle",
                        text: "保存短语后，还需在「高级安装」用「自定义提示」模式安装 hook，并完全退出重开微信才会生效。")
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
                Text("说明：{content} 目前恒为空——真实运行时不会填入被撤回的内容，因此预览里也会被省略。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
}

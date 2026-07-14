import SwiftUI

struct HomeView: View {
    @EnvironmentObject var state: AppState
    var goToUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let banner = state.banner {
                BannerView(banner: banner)
            }

            statusCard

            switch state.supportStatus {
            case .supported:
                supportedActions
            case .unsupported(let build):
                unsupportedCard(build: build)
            case .noWeChat:
                noWeChatCard
            case .unknown:
                Card { ProgressView().controlSize(.small) }
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "message.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.accent.opacity(0.12)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("微信 \(state.displayVersion)")
                        .font(.title3.weight(.semibold))
                    Text("构建号 \(state.displayBuild)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    supportPill
                    if state.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(state.busyMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            Task { await state.refresh() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var supportPill: some View {
        switch state.supportStatus {
        case .supported:
            return AnyView(StatusPill(tone: .good, text: "此版本受支持", systemImage: "checkmark.seal.fill"))
        case .unsupported:
            return AnyView(StatusPill(tone: .warn, text: "暂不支持", systemImage: "exclamationmark.triangle.fill"))
        case .noWeChat:
            return AnyView(StatusPill(tone: .neutral, text: "未检测到微信", systemImage: "questionmark.circle"))
        case .unknown:
            return AnyView(StatusPill(tone: .neutral, text: "检测中…"))
        }
    }

    // MARK: - Supported

    private var supportedActions: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(text: "静默防撤回")
                    Spacer()
                    installStatePill
                }
                Text("别人撤回的消息会原样留在聊天里，不显示任何提示。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if state.wechatRunning {
                    HStack(spacing: 10) {
                        HintRow(systemImage: "exclamationmark.circle.fill",
                                text: "安装前请先完全退出微信。", tint: .orange)
                        Button("退出微信") { Task { await state.quitWeChat() } }
                            .disabled(state.busy)
                    }
                }

                Button {
                    Task { await state.install(InstallRequest(mode: .silent)) }
                } label: {
                    Text(state.installState == .installed ? "重新安装防撤回" : "开启防撤回")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
                .disabled(state.busy || state.wechatRunning)

                HintRow(systemImage: "info.circle",
                        text: "安装会修改并重新签名微信，过程中会弹出一次管理员密码。装完请完全退出并重开微信。")
            }
        }
    }

    private var installStatePill: some View {
        switch state.installState {
        case .installed: return AnyView(StatusPill(tone: .good, text: "已开启", systemImage: "checkmark.circle.fill"))
        case .notInstalled: return AnyView(StatusPill(tone: .neutral, text: "未开启"))
        case .mismatch: return AnyView(StatusPill(tone: .warn, text: "数据不匹配"))
        case .unknown: return AnyView(EmptyView())
        }
    }

    // MARK: - Unsupported / no WeChat

    private func unsupportedCard(build: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "此版本暂不支持")
                Text("当前微信构建号 \(build) 还不在补丁数据里。支持新版本通常只需要更新一份很小的补丁数据——先试试拉取最新数据。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        Task { await state.updatePatchData() }
                    } label: {
                        Label("拉取最新补丁数据", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(state.busy)

                    Button("更多更新选项") { goToUpdates() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var noWeChatCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "未检测到微信")
                Text("没有在 \(state.appPath) 找到微信。请确认已安装 macOS 版微信 4。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("重新检测") { Task { await state.refresh() } }
                    .disabled(state.busy)
            }
        }
    }
}

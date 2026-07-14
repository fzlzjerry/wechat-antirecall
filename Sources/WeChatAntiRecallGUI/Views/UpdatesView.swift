import SwiftUI
import AppKit

struct UpdatesView: View {
    @EnvironmentObject var state: AppState
    @State private var release: ReleaseInfo?
    @State private var checkingRelease = false
    @State private var releaseError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("检查更新").font(.title2.weight(.semibold))

            if let banner = state.banner {
                BannerView(banner: banner)
            }

            patchDataCard
            appUpdateCard
            sourceBuildCard
        }
    }

    private var patchDataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "补丁数据")
                    Spacer()
                    StatusPill(
                        tone: state.effectiveCatalogSourceIsDownloaded ? .good : .neutral,
                        text: state.effectiveCatalogSourceIsDownloaded ? "已更新" : "使用内置",
                        systemImage: state.effectiveCatalogSourceIsDownloaded ? "arrow.down.circle.fill" : "shippingbox")
                }
                Text("补丁数据（patches.json）决定支持哪些微信版本。更新它就能即时支持新版微信的静默防撤回，无需重装 App。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let count = state.versions?.catalog.count {
                    KeyValueRow(key: "当前覆盖", value: "\(count) 个构建号")
                }
                HStack {
                    Button {
                        Task { await state.updatePatchData() }
                    } label: {
                        Label("拉取最新补丁数据", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(state.busy)

                    if state.effectiveCatalogSourceIsDownloaded {
                        Button("回退到内置") { Task { await state.revertToBundledCatalog() } }
                            .buttonStyle(.bordered)
                            .disabled(state.busy)
                    }
                }
            }
        }
    }

    private var appUpdateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: "应用更新")
                Text("新功能、bug 修复，以及新版微信的自定义提示支持，需要更新 App 本身。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let release {
                    KeyValueRow(key: "最新发布", value: "\(release.name) (\(release.tag))")
                }
                if let releaseError {
                    HintRow(systemImage: "exclamationmark.triangle", text: releaseError, tint: .orange)
                }

                HStack {
                    Button {
                        checkRelease()
                    } label: {
                        HStack(spacing: 6) {
                            if checkingRelease { ProgressView().controlSize(.small) }
                            Text("检查应用更新")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(checkingRelease)

                    if let release {
                        Button("打开下载页") { NSWorkspace.shared.open(release.htmlURL) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var sourceBuildCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel(text: "从源码构建（高级）")
                    Spacer()
                    if state.usingBuiltFromSource {
                        StatusPill(tone: .good, text: "使用源码构建", systemImage: "hammer.fill")
                    }
                }
                Text("拉取最新源码并在本机编译，获得最前沿的代码（含新版微信的自定义提示支持）。需要 Xcode 命令行工具。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.toolchainAvailable {
                    HStack {
                        Button {
                            Task { await state.buildFromSource() }
                        } label: {
                            HStack(spacing: 6) {
                                if state.busy { ProgressView().controlSize(.small) }
                                Text("拉取源码并构建")
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(state.busy)

                        if state.usingBuiltFromSource {
                            Button("回退到内置") { Task { await state.revertSourceBuild() } }
                                .buttonStyle(.bordered).disabled(state.busy)
                        }
                    }
                    HintRow(systemImage: "clock", text: "首次构建可能需要一两分钟。进度见下方「查看详情」。")
                } else {
                    HintRow(systemImage: "wrench.and.screwdriver",
                            text: "未检测到 Xcode 命令行工具。在「终端」运行 xcode-select --install 安装后可用。")
                    Button("打开项目主页") {
                        NSWorkspace.shared.open(Upstream.releasesPage.deletingLastPathComponent())
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .onAppear { Task { await state.checkToolchain() } }
    }

    private func checkRelease() {
        checkingRelease = true
        releaseError = nil
        Task {
            do {
                let info = try await UpdateService.checkLatestRelease()
                await MainActor.run { self.release = info; self.checkingRelease = false }
            } catch {
                await MainActor.run { self.releaseError = error.localizedDescription; self.checkingRelease = false }
            }
        }
    }
}

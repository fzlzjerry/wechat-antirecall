import SwiftUI

enum NavSection: String, CaseIterable, Identifiable {
    case home
    case tipPhrase
    case advanced
    case clone
    case restore
    case updates
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "首页"
        case .tipPhrase: return "自定义提示"
        case .advanced: return "高级安装"
        case .clone: return "微信多开"
        case .restore: return "恢复 / 卸载"
        case .updates: return "检查更新"
        case .permissions: return "权限与帮助"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .tipPhrase: return "text.bubble.fill"
        case .advanced: return "slider.horizontal.3"
        case .clone: return "square.on.square"
        case .restore: return "arrow.uturn.backward.circle.fill"
        case .updates: return "arrow.down.circle.fill"
        case .permissions: return "lock.shield.fill"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @SceneStorage("navigation.section") private var selectedSectionRaw = NavSection.home.rawValue
    @SceneStorage("install.mode") private var installModeRaw = InstallMode.silent.rawValue
    @SceneStorage("install.blockUpdate") private var blockUpdate = false
    @SceneStorage("install.multiInstance") private var multiInstance = false

    private var selectedSection: NavSection {
        NavSection(rawValue: selectedSectionRaw) ?? .home
    }

    private var selection: Binding<NavSection?> {
        Binding(
            get: { selectedSection },
            set: { selectedSectionRaw = ($0 ?? .home).rawValue })
    }

    private var installMode: Binding<InstallMode> {
        Binding(
            get: { InstallMode(rawValue: installModeRaw) ?? .silent },
            set: { installModeRaw = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .onAppear { state.onAppear() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("微信防撤回").font(.headline)
                    Text("WeChat AntiRecall").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            List(selection: selection) {
                ForEach(NavSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

            WeChatRunningIndicator()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 210)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch selectedSection {
                    case .home:
                        HomeView(
                            goToCustomTip: { navigate(to: .tipPhrase) },
                            goToAdvanced: { navigate(to: .advanced) },
                            goToUpdates: { navigate(to: .updates) })
                    case .tipPhrase: TipPhraseView()
                    case .advanced:
                        AdvancedInstallView(
                            mode: installMode,
                            blockUpdate: $blockUpdate,
                            multiInstance: $multiInstance,
                            goToRestore: { navigate(to: .restore) })
                    case .clone: CloneView()
                    case .restore: RestoreView()
                    case .updates: UpdatesView()
                    case .permissions: PermissionsView()
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            LogDrawer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func navigate(to section: NavSection) {
        selectedSectionRaw = section.rawValue
    }
}

struct WeChatRunningIndicator: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.wechatRunning ? Color.orange : Theme.accent)
                .frame(width: 8, height: 8)
            Text(state.wechatRunning ? "微信运行中" : "微信已退出")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if state.wechatRunning {
                Button("退出") {
                    Task { await state.quitWeChat() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(state.busy)
            }
        }
    }
}

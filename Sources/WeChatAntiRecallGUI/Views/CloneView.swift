import SwiftUI

struct CloneView: View {
    @EnvironmentObject var state: AppState

    @State private var count = 2
    @State private var namePrefix = "WeChat"
    @State private var outputDir = "/Applications"
    @State private var keepURLSchemes = false
    @State private var replace = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("微信多开").font(.title2.weight(.semibold))

            if let banner = state.banner { BannerView(banner: banner) }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "复制出独立的微信")
                    Text("多开不改动原始微信，而是复制出独立的 App 副本，可同时登录多个账号。任何版本都能用，不依赖补丁数据。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Stepper(value: $count, in: 1...9) {
                        HStack { Text("副本数量"); Spacer(); Text("\(count)").foregroundStyle(.secondary) }
                    }
                    HStack {
                        Text("名称前缀")
                        Spacer()
                        TextField("WeChat", text: $namePrefix).frame(width: 160).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("输出目录")
                        Spacer()
                        TextField("/Applications", text: $outputDir).frame(width: 220).textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    Toggle(isOn: $keepURLSchemes) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("保留 URL Scheme")
                            Text("默认移除，避免系统回调随机落到副本").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(Theme.accent)
                    Toggle(isOn: $replace) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("覆盖已存在的副本")
                            Text("把旧副本改名为时间戳备份后再创建").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(Theme.accent)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button {
                            Task {
                                await state.clone(count: count, namePrefix: namePrefix,
                                                  outputDir: outputDir, keepURLSchemes: keepURLSchemes, replace: replace)
                            }
                        } label: {
                            Text("创建多开副本").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .disabled(state.busy || namePrefix.trimmingCharacters(in: .whitespaces).isEmpty)
                        if state.busy {
                            ProgressView().controlSize(.small)
                            Text(state.busyMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HintRow(systemImage: "info.circle", text: "创建副本需要写入「应用程序」，会弹出一次管理员密码。每个副本通常要单独登录。")
                }
            }
        }
    }
}

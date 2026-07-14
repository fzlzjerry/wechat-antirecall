import SwiftUI

struct LogDrawer: View {
    @EnvironmentObject var state: AppState
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Image(systemName: "terminal")
                            .font(.caption)
                        Text("查看详情")
                            .font(.caption.weight(.medium))
                        if !state.logLines.isEmpty {
                            Text("\(state.logLines.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if state.busy {
                    ProgressView().controlSize(.small)
                }
                if !state.logLines.isEmpty {
                    Button("清空") { state.clearLog() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if expanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if state.logLines.isEmpty {
                                Text("暂无日志。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            }
                            ForEach(Array(state.logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                    .frame(height: 160)
                    .onChange(of: state.logLines.count) { _ in
                        if let last = state.logLines.indices.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

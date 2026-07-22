import SwiftUI

/// 麦时二级页 sheet（对齐安卓 [PartyMicTimeDetailActivity]）。
///
/// **两个入口**（对齐安卓 :55-59）：
/// - 主看板总麦时点 → statDate=nil（周期维度查全部房间）
/// - 每日明细行麦时点 → statDate=<day>（单日维度按房间聚合）
///
/// 视觉：按房间列表，每行 room name + 总/语音/视频秒数。
struct PartyMicTimeDetailView: View {
    @StateObject private var store: PartyMicTimeDetailStore
    @Environment(\.dismiss) private var dismiss

    init(dateType: PartyDataDateType, statDate: String?) {
        _store = StateObject(wrappedValue: PartyMicTimeDetailStore(dateType: dateType, statDate: statDate))
    }

    private var subtitle: String {
        if let d = store.statDate, !d.isEmpty {
            return d  // 单日维度
        }
        // 周期维度：显示子期间标签
        switch store.dateType {
        case .thisWeek:  return L10n.commonThisWeek
        case .lastWeek:  return L10n.commonLastWeek
        case .thisMonth: return L10n.commonThisMonth
        case .lastMonth: return L10n.commonLastMonth
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.screenBackground.ignoresSafeArea()

                content
            }
            .navigationTitle(L10n.partyMicTimeDetailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.Palette.screenBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(L10n.commonClose)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { store.onAppear() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)

        case .loaded(let items):
            if items.isEmpty {
                emptyView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        subtitleHeader
                        LazyVStack(spacing: 10) {
                            ForEach(items) { item in
                                row(item)
                            }
                        }
                        Color.clear.frame(height: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }

        case .error(let msg):
            errorView(msg)
        }
    }

    private var subtitleHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func row(_ item: PartyMicTimeDetailItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.roomName.isEmpty ? "-" : item.roomName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(alignment: .top, spacing: 12) {
                cell(iconSystem: "clock.fill",
                     iconColor: Color(hex: 0xF640DC),
                     value: LiveDataFormatter.hhmmss(item.totalSeconds),
                     label: L10n.partyMicTimeTotal)
                cell(iconSystem: "mic.fill",
                     iconColor: Color(hex: 0xFFE600),
                     value: LiveDataFormatter.hhmmss(item.voiceSeconds),
                     label: L10n.partyMicTimeVoice)
                cell(iconSystem: "video.fill",
                     iconColor: Color(hex: 0x4FC3F7),
                     value: LiveDataFormatter.hhmmss(item.videoSeconds),
                     label: L10n.partyMicTimeVideo)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func cell(iconSystem: String, iconColor: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: iconSystem)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.5))
            Text(L10n.partyMicTimeEmpty)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
            Text(msg)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                store.reload()
            } label: {
                Text(L10n.commonRetry)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

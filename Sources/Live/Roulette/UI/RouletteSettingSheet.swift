import SwiftUI

/// Roulette 配置 sheet（对齐 H5 liveRoulettePopup.vue 主 popup）
///
/// **本轮范围**（Level B）：显示 4-8 奖项 + 启用开关 + 价格 + 编辑/规则按钮（详情弹窗 TODO H 里程碑）
struct RouletteSettingSheet: View {
    @StateObject private var store: RouletteStore
    @Binding var isPresented: Bool

    init(anchorUserId: String, liveRoomId: String, isPresented: Binding<Bool>) {
        self._store = StateObject(wrappedValue: RouletteStore(anchorUserId: anchorUserId,
                                                              liveRoomId: liveRoomId))
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .onAppear { store.loadIfNeeded() }
    }

    /// v2 修订（2026-07-09）：删顶部右 X 关闭按钮 —— 用户反馈"sheet 顶部关闭按钮误触"。
    /// 关闭走 sheet drag indicator + swipe down。左侧 ? 规则入口保留（不同语义，非关闭按钮）。
    private var header: some View {
        HStack {
            // 规则入口按钮（TODO H 里程碑接入 rpsRulesSheet）
            Button {
                // TODO: 打开规则 sheet
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(L10n.liveRoomRouletteRules))

            Spacer()

            Text(L10n.liveRoomRouletteSettingTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            // 保持左右对称：右侧占位 44x44（原 X 按钮位）
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            configForm
        case .error:
            errorView
        }
    }

    private var configForm: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 启用开关
                HStack {
                    Text(L10n.liveRoomRouletteEnable)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { store.draftConfig.enabled },
                        set: { _ in store.toggleEnabled() }
                    ))
                    .labelsHidden()
                    .tint(Color(hex: 0xFFBB02))
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                // 价格
                HStack {
                    Text(L10n.liveRoomRoulettePrice)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    HStack(spacing: 4) {
                        Image("liveRoomDiamondBadge")
                            .resizable().frame(width: 14, height: 14)
                        Text("\(store.draftConfig.price)")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(Color(hex: 0xFFE600))
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                // 奖项列表 + 编辑按钮
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.liveRoomRouletteSectors)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Button {
                            // TODO H 里程碑：弹编辑项目 popup
                        } label: {
                            Text(L10n.liveRoomRouletteEdit)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color(hex: 0xFFBB02))
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Array(store.draftConfig.sectors.enumerated()), id: \.offset) { _, sector in
                            Text(sector)
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        if store.draftConfig.sectors.isEmpty {
                            Text(L10n.liveRoomRouletteSectorsEmpty)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 32)
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Text(L10n.liveRoomRouletteErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
            Button {
                store.retry()
            } label: {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import SwiftUI

// v25 (2026-07-17) H 里程碑 · LiveGiftTask spec §3.1:
// - LiveRoomComingSoonPopup (占位 popup 容器) 已删,唯一 caller TopPlaceholderPopupsModifier 同步删除
// - TopPlaceholderPopupsModifier 已删:Task 迁 LiveGiftTaskSheet(Sources/Live/GiftTask/);
//   Audience 已在 v11 死代码化(tap → showRankSheet,showAudience binding 从未被写为 true)
// - L10n.swift 里 liveRoomComingSoonTask / liveRoomComingSoonAudience 变孤儿 key,保留以免破坏
//   en/ar/tr Localizable.strings 三份翻译(spec §3.1 v2 明示"先 grep 确认再删",保守保留)

/// v7 顶部 3 sheet（Contribution / Rank / Roulette）+ Roulette intro overlay 合并 ViewModifier —— 缓解
/// LiveRoomView.body 里 3 sheet + 1 overlay 让 SwiftUI 类型推导超时（与 TopPlaceholderPopupsModifier 同源修法）
struct TopSheetsModifier: ViewModifier {
    let uidStr: String
    let roomIdStr: String
    @ObservedObject var contributionStore: LiveContributionStore
    @Binding var showContribution: Bool
    let onContributionUserTap: (String) -> Void
    /// v16：Rank 徽章 tap → 弹主播收礼周榜（girlWeeklyRank 语义）
    @Binding var showRank: Bool
    /// v16：观众数字 tap → 弹观众+送礼榜（userWeeklyRank 语义）
    @Binding var showUserWeeklyRank: Bool
    @Binding var userWeeklyRankInitialTopTab: RankSheetTopTab
    /// v14 rank sheet load 完成后回填顶部 rank 徽章
    let onRankUpdate: (Int?) -> Void
    @Binding var showRouletteSetting: Bool
    @Binding var showRouletteIntro: Bool
    /// 转盘启用状态变化回调（sheet 内 Enable/Close/Save 成功后回传给 LiveRoomView 更新顶部 icon）
    let onRouletteEnabledChanged: (Bool) -> Void
    /// Enable 成功后 sheet 立即关闭，toast 需上抛到 LiveRoomView 全屏层展示
    let onRouletteToast: (String) -> Void
    @State private var pendingUserCardUserId: String?

    func body(content: Content) -> some View {
        // v17: 所有直播间 sheet 加 .fraction(0.4) + .large 双 detents —— 默认 2/5 屏，允许用户拖大
        // 对齐用户明示"不要遮挡直播画面"
        content
            .sheet(isPresented: $showContribution, onDismiss: presentPendingUserCardAfterSheetDismissal) {
                ContributionSheetView(anchorId: uidStr,
                                      roomId: roomIdStr,
                                      currentIncome: contributionStore.currentLiveIncome,
                                      isPresented: $showContribution,
                                      onUserTap: { userId in
                                          guard shouldPresentUserCard(for: userId) else { return }
                                          pendingUserCardUserId = userId
                                          showContribution = false
                                      })
                    .sheetTopInset()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)   // 用顶部 X 关闭，隐藏 drag indicator
            }
            .sheet(isPresented: $showRank, onDismiss: presentPendingUserCardAfterSheetDismissal) {
                // Rank 徽章入口 → 主播收礼周榜（对齐 H5 girlWeeklyRank.vue）
                RankSheetView(anchorUserId: uidStr,
                              isPresented: $showRank,
                              onRankUpdate: onRankUpdate,
                              onUserTap: { userId in
                                  guard shouldPresentUserCard(for: userId) else { return }
                                  pendingUserCardUserId = userId
                                  showRank = false
                              })
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showUserWeeklyRank, onDismiss: presentPendingUserCardAfterSheetDismissal) {
                // 观众数字入口 → 观众列表 + 送礼榜（对齐 H5 userWeeklyRank.vue）
                UserWeeklyRankSheetView(
                    isPresented: $showUserWeeklyRank,
                    anchorUserId: Int(uidStr) ?? 0,
                    dbId: Int(roomIdStr) ?? 0,
                    initialTopTab: userWeeklyRankInitialTopTab,
                    onUserTap: { userId in
                        guard shouldPresentUserCard(for: userId) else { return }
                        pendingUserCardUserId = userId
                        showUserWeeklyRank = false
                    }
                )
                    .sheetTopInset()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showRouletteSetting) {
                RouletteSettingSheet(anchorUserId: uidStr,
                                     liveRoomId: roomIdStr,
                                     isPresented: $showRouletteSetting,
                                     onEnabledChanged: onRouletteEnabledChanged,
                                     onToast: onRouletteToast)
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.65)])
                    .presentationDragIndicator(.visible)
            }
            .overlay {
                RouletteIntroPopup(isPresented: $showRouletteIntro, onFinish: { [uid = uidStr] in
                    UserDefaults.standard.set(true, forKey: RouletteStore.introShownKey(userId: uid))
                    // intro 完成后立即打开 setting sheet
                    showRouletteSetting = true
                })
            }
    }

    private func presentPendingUserCardAfterSheetDismissal() {
        guard let userId = pendingUserCardUserId else { return }
        pendingUserCardUserId = nil
        onContributionUserTap(userId)
    }

    private func shouldPresentUserCard(for userId: String) -> Bool {
        guard !userId.isEmpty else { return false }
        return userId != String(SessionStore.shared.user?.userId ?? 0)
    }
}

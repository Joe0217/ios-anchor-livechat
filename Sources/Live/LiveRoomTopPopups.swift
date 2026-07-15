import SwiftUI

/// 顶部 Task / Audience placeholder popup（仅这 2 个保留 coming-soon 模式；
/// Contribution / Rank / Roulette 已在 v7 迁到独立 sheet 视图对齐 H5）
///
/// **视觉**：复用 [PKPopupCard](../PK/UI/PKPopupCard.swift) 通用 popup 容器（gradient card + close X）。
struct LiveRoomComingSoonPopup: View {
    @Binding var isPresented: Bool
    let title: String
    /// 弹窗正文（不叫 body 避免与 View 协议 body 属性冲突）
    let message: String

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: title) {
            VStack(spacing: 20) {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                PKPopupButton(title: L10n.liveRoomCloseA11y, style: .solidPurple) {
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                }
                .padding(.horizontal, 40)
            }
        }
    }
}

/// 2 个 placeholder popup 合并为一个 ViewModifier，避免 LiveRoomView.body 里连续 .overlay
/// 让 SwiftUI 类型推导超时。
///
/// **v7 收缩**（2026-07-07）：从 5 个（Task/Contribution/Rank/Audience/Roulette）缩为 2 个（Task/Audience）——
/// Contribution/Rank/Roulette 已迁到独立 sheet 视图对齐 H5（Sources/Live/{Contribution,Rank,Roulette}/）
struct TopPlaceholderPopupsModifier: ViewModifier {
    @Binding var showTask: Bool
    @Binding var showAudience: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                LiveRoomComingSoonPopup(isPresented: $showTask,
                                        title: L10n.liveRoomTaskA11y,
                                        message: L10n.liveRoomComingSoonTask)
            }
            .overlay {
                LiveRoomComingSoonPopup(isPresented: $showAudience,
                                        title: L10n.liveRoomAudienceA11y,
                                        message: L10n.liveRoomComingSoonAudience)
            }
    }
}

/// v7 顶部 3 sheet（Contribution / Rank / Roulette）+ Roulette intro overlay 合并 ViewModifier —— 缓解
/// LiveRoomView.body 里 3 sheet + 1 overlay 让 SwiftUI 类型推导超时（与 TopPlaceholderPopupsModifier 同源修法）
struct TopSheetsModifier: ViewModifier {
    let uidStr: String
    let roomIdStr: String
    @Binding var showContribution: Bool
    /// v16：Rank 徽章 tap → 弹主播收礼周榜（girlWeeklyRank 语义）
    @Binding var showRank: Bool
    /// v16：观众数字 tap → 弹观众+送礼榜（userWeeklyRank 语义）
    @Binding var showUserWeeklyRank: Bool
    /// v14 rank sheet load 完成后回填顶部 rank 徽章
    let onRankUpdate: (Int?) -> Void
    @Binding var showRouletteSetting: Bool
    @Binding var showRouletteIntro: Bool
    /// 转盘启用状态变化回调（sheet 内 Enable/Close/Save 成功后回传给 LiveRoomView 更新顶部 icon）
    let onRouletteEnabledChanged: (Bool) -> Void
    /// Enable 成功后 sheet 立即关闭，toast 需上抛到 LiveRoomView 全屏层展示
    let onRouletteToast: (String) -> Void

    func body(content: Content) -> some View {
        // v17: 所有直播间 sheet 加 .fraction(0.4) + .large 双 detents —— 默认 2/5 屏，允许用户拖大
        // 对齐用户明示"不要遮挡直播画面"
        content
            .sheet(isPresented: $showContribution) {
                ContributionSheetView(anchorId: uidStr,
                                      roomId: roomIdStr,
                                      isPresented: $showContribution)
                    .sheetTopInset()
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)   // 用顶部 X 关闭，隐藏 drag indicator
            }
            .sheet(isPresented: $showRank) {
                // Rank 徽章入口 → 主播收礼周榜（对齐 H5 girlWeeklyRank.vue）
                RankSheetView(anchorUserId: uidStr,
                              isPresented: $showRank,
                              onRankUpdate: onRankUpdate)
                    .presentationDetents([.fraction(0.4)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showUserWeeklyRank) {
                // 观众数字入口 → 观众列表 + 送礼榜（对齐 H5 userWeeklyRank.vue）
                UserWeeklyRankSheetView(
                    isPresented: $showUserWeeklyRank,
                    anchorUserId: Int(uidStr) ?? 0,
                    dbId: Int(roomIdStr) ?? 0
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
}

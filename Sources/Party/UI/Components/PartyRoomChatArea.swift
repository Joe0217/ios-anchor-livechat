import SwiftUI

/// Party 房间聊天区（欢迎绿字 + 聊天消息 + 礼物消息）。
///
/// MVP：welcome 用 `store.roomInfo?.greetingMessage` fallback 到设计稿默认文案；
/// 消息列表复用 PartyMessageListView（父 view 传入 chat store），
/// 本组件只负责 tab + welcome banner + gift banner 视觉外框。
struct PartyRoomChatArea: View {
    @Binding var filter: PartyRoomChatFilter
    let welcomeMessage: String
    let chat: PartyRoomChatManager
    let lastGiftEvent: PartyGiftEvent?
    let canDeleteTextMessages: Bool
    let onDeleteTextMessage: (UnifiedPublicChatMessage) async -> Bool
    let onWinnerActivity: ((String) -> Void)?
    /// 审核账号不展示 Gift 标签，也不保留收礼类缓存消息。
    var showsGiftContent: Bool = true
    var showsLotteryContent: Bool = true
    var showsPartyGameContent: Bool = true
    /// 107 保留骰子/猜拳结果，但不因此放开 PK、PartyBattle 或其他游戏消息。
    var showsFreePartyGameContent: Bool = true
    var showsActivityContent: Bool = true
    var showsVirtualItemContent: Bool = true
    /// 107 的 Party 公屏保留普通头像、昵称与正文，不展示头像框、VIP、等级或聊天气泡。
    var usesPlainSenderStyle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartyRoomChatTabStrip(selection: $filter, showsGiftTab: showsGiftContent)
            // v3（2026-07-15）：welcomeBanner 只在 All tab 顶部显示（对齐 H5 public-chat.vue L194-197
            // 只在 `state.tabList[0]` 顶部渲染 convention 绿字）；Chat/Gift tab 隐藏。
            if filter == .all {
                welcomeBanner
            }
            messageList
        }
        .onAppear(perform: resetUnavailableGiftFilter)
        .onChange(of: showsGiftContent) { _ in
            resetUnavailableGiftFilter()
        }
    }

    @ViewBuilder
    private var welcomeBanner: some View {
        if !welcomeMessage.isEmpty {
            Text(welcomeMessage)
                .font(Theme.Typography.partyRoomWelcome)
                .foregroundColor(Theme.Palette.partyRoomWelcomeText)
                .lineLimit(3)
                .padding(.horizontal, Theme.Metric.partyRoomChatHPadding)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
    }

    private var messageList: some View {
        // P1-6：复用已有 PartyMessageListView（chat 观测已在子 view 内切分）
        // v10：filter 透传（All/Chat/Gift 三档真过滤，对齐 H5/Android 派对房蓝本）
        PartyMessageListView(
            chat: chat,
            filter: filter,
            lastGiftEvent: lastGiftEvent,
            showsGiftMessages: showsGiftContent,
            showsLotteryMessages: showsLotteryContent,
            showsPartyGameMessages: showsPartyGameContent,
            showsFreePartyGameMessages: showsFreePartyGameContent,
            showsActivityMessages: showsActivityContent,
            showsVirtualItemMessages: showsVirtualItemContent,
            usesPlainSenderStyle: usesPlainSenderStyle,
            canDeleteTextMessages: canDeleteTextMessages,
            onDeleteTextMessage: onDeleteTextMessage,
            onWinnerActivity: onWinnerActivity
        )
            .padding(.horizontal, Theme.Metric.partyRoomChatHPadding)
    }

    private func resetUnavailableGiftFilter() {
        if !showsGiftContent, filter == .gift {
            filter = .all
        }
    }
}

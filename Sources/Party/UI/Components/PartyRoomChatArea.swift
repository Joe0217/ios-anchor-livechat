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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartyRoomChatTabStrip(selection: $filter)
            // v3（2026-07-15）：welcomeBanner 只在 All tab 顶部显示（对齐 H5 public-chat.vue L194-197
            // 只在 `state.tabList[0]` 顶部渲染 convention 绿字）；Chat/Gift tab 隐藏。
            if filter == .all {
                welcomeBanner
            }
            messageList
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
            canDeleteTextMessages: canDeleteTextMessages,
            onDeleteTextMessage: onDeleteTextMessage
        )
            .padding(.horizontal, Theme.Metric.partyRoomChatHPadding)
    }
}

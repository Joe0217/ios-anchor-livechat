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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PartyRoomChatTabStrip(selection: $filter)
            welcomeBanner
            messageList
        }
    }

    private var welcomeBanner: some View {
        Text(welcomeMessage)
            .font(Theme.Typography.partyRoomWelcome)
            .foregroundColor(Theme.Palette.partyRoomWelcomeText)
            .lineLimit(3)
            .padding(.horizontal, Theme.Metric.partyRoomChatHPadding)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private var messageList: some View {
        // P1-6：复用已有 PartyMessageListView（chat 观测已在子 view 内切分）
        PartyMessageListView(chat: chat, lastGiftEvent: lastGiftEvent)
            .padding(.horizontal, Theme.Metric.partyRoomChatHPadding)
    }
}

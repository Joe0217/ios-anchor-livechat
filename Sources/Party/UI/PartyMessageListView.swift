import SwiftUI

/// 派对房公屏消息列表 + 最近一条送礼提示（review 202606252033 P1-6 拆出）。
///
/// 拆出原因：
/// - `chat.messages` 高频变化（活跃房 >5 条/秒）每次都触发整个 PartyRoomView body 重算
/// - 顶层 body 重算 → seatGrid + LazyVGrid 重新 evaluate → PartyRemoteVideoView / CameraPreview 抖动
/// - 抽到独立子 view 后，@ObservedObject chat 仅触发本子 view 重 evaluate；麦位区完全不受影响
///
/// 入参：
/// - chat: 观测 messages + 历史拉取状态
/// - lastGiftEvent: 仅显示最近一条送礼（落公屏，不归入 chat.messages 数据流）
struct PartyMessageListView: View {
    @ObservedObject var chat: PartyRoomChatManager
    let lastGiftEvent: PartyGiftEvent?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(chat.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if let g = lastGiftEvent {
                        Text(String(format: L10n.Party.giftMessageFormat,
                                    g.senderNickname ?? L10n.Party.defaultUser,
                                    g.giftName ?? L10n.Party.defaultGift,
                                    g.num))
                            .font(.system(size: 13))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12)
                            .id("gift_\(g.timestamp)")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: chat.messages.count) { _ in
                if let last = chat.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func messageRow(_ msg: PartyChatMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if let n = msg.nickname, !n.isEmpty {
                Text("\(n):")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(msg.role == .owner ? .orange : .blue)
            }
            Text(msg.text).font(.system(size: 13))
            Spacer(minLength: 0)
            if msg.isLocal {
                Image(systemName: "clock").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }
}

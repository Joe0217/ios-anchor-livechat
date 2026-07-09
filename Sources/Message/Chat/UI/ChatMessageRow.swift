import SwiftUI

/// 消息 row（H-2 spec §4，对齐 H5 `msgItem.vue`）。
///
/// **结构**（HStack）：
/// - 对方：`头像 + 气泡 + Spacer`（左对齐）
/// - 我方：`Spacer + 气泡 + 状态图标 + 头像`（右对齐）
///
/// **视觉**：头像 36 圆形；气泡按 content 类型分发；状态图标（sending/read/failed）气泡右下侧
struct ChatMessageRow: View {
    let message: ChatMessage
    let myAvatarURL: URL?
    let peerAvatarURL: URL?
    /// 对端业务 userId（非 yxAccId）—— tap 对方头像跳详情页用；nil 时头像不可 tap（对齐 H5 `msgItem.vue` handelClickUserAvatar 逻辑）
    var peerUserId: Int? = nil
    /// 音频播放的 clientMsgId（nil 表示无播放中）
    let playingAudioClientId: String?
    let onTapAudio: (ChatMessage) -> Void
    let onTapVideo: (ChatMessage) -> Void
    let onTapImage: (ChatMessage) -> Void
    let onResend: (ChatMessage) -> Void
    /// Batch 6.3.3：翻译后文本；nil = 未翻译；非 nil = 显示译文（内存态,不持久化）
    var translatedText: String? = nil
    /// Batch 6.3.3：长按翻译回调（对方文字消息才 non-nil）
    var onLongPressTranslate: ((ChatMessage) -> Void)? = nil

    var body: some View {
        // 系统提示（居中灰字条）不走左右 avatar 布局
        if case .systemTip(let text, let weakType) = message.content {
            SystemTipRow(text: text, weakType: weakType)
                .padding(.horizontal, 12)
        } else if case .system = message.content {
            // 兜底占位不展示（保数据便于 H-3+ 分发）
            EmptyView()
        } else if case .chatTip(_, let text, _) = message.content {
            // H-3 spec §2.5：回复积分 4 tip 居中展示；Step 1a 占位样式，Step 1b 替换 ChatTipRow(kind, text)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .center, spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    if message.isOutgoing {
                        Spacer(minLength: 40)
                        statusIndicator
                        bubbleView
                        // 我方 = 主播端主播自己（kind: .anchor）
                        AvatarView(url: myAvatarURL, size: ChatConstants.listAvatarSize, kind: .anchor)
                    } else {
                        // 对方 = 用户（kind: .user）；tap 头像跳详情页(对齐 H5 msgItem.vue handelClickUserAvatar)。
                        // peerUserId 由 caller(ChatDetailView) 从 ConversationProfile 派生;nil 时降级不响应
                        // 而非 NavigationLink 空 value(避免路径污染)。
                        peerAvatarButton
                        bubbleView
                        Spacer(minLength: 40)
                    }
                }
                // H-3 spec §4.8 / §F-25：我方消息被拒（NIM 7101 拉黑）→ 气泡下方追加 RefusedInlineTip
                if message.isOutgoing, case .refused = message.status {
                    RefusedInlineTip()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// 对方头像:有 peerUserId → NavigationLink 走 UserProfileRoute(祖先 NavigationStack 接管);
    /// 无 → 静态 AvatarView 不响应 tap(profile 未拉齐场景)。
    @ViewBuilder
    private var peerAvatarButton: some View {
        if let uid = peerUserId {
            NavigationLink(value: UserProfileRoute.userId(String(uid))) {
                AvatarView(url: peerAvatarURL, size: ChatConstants.listAvatarSize, kind: .user)
            }
            .buttonStyle(.plain)
        } else {
            AvatarView(url: peerAvatarURL, size: ChatConstants.listAvatarSize, kind: .user)
        }
    }

    @ViewBuilder
    private var bubbleView: some View {
        switch message.content {
        case .text(let s):
            // Batch 3.9：传 chatBubble URL 让 TextBubbleView 用 NinePatchImageView 渲染主播穿戴的气泡背景
            // Batch 6.3.3：对方文字消息可长按翻译；我方消息不给 onLongPressTranslate 关闭该功能
            TextBubbleView(
                text: s,
                isOutgoing: message.isOutgoing,
                chatBubble: message.chatBubble,
                translatedText: translatedText,
                onLongPressTranslate: message.isOutgoing ? nil : { onLongPressTranslate?(message) }
            )
        case .image(let url, _):
            ImageBubbleView(url: url)
                .onTapGesture { onTapImage(message) }
        case .video(_, let cover, let dur):
            VideoBubbleView(thumbnailUrl: cover, dur: dur) { onTapVideo(message) }
        case .audio(_, let dur):
            AudioBubbleView(
                dur: dur,
                isOutgoing: message.isOutgoing,
                isPlaying: playingAudioClientId == (message.clientMsgId ?? message.id),
                onTap: { onTapAudio(message) }
            )
        case .systemGift(let smallImg, let giftNum):
            SystemGiftBubbleView(smallImg: smallImg, giftNum: giftNum)
        case .missedCall(let kind):
            MissedCallBubbleView(kind: kind, isOutgoing: message.isOutgoing)
        case .systemTip, .system, .chatTip:
            // 已在 body 上层拦截（居中提示 / 兜底不展示 / tip 已上层渲染）
            EmptyView()
        // Batch 6.3.2：私密图片/视频气泡走 PrivateImage/VideoBubbleView 叠 lock/unlock icon（spec §F-4 / §F-5）
        case .privateImage(let url, let lockStatus):
            PrivateImageBubbleView(url: url, lockStatus: lockStatus)
                .onTapGesture { onTapImage(message) }
        case .privateVideo(let url, let cover, let dur, let lockStatus):
            PrivateVideoBubbleView(url: url, coverUrl: cover, dur: dur, lockStatus: lockStatus) {
                onTapVideo(message)
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        // 只对我方 outgoing 显示状态；对方 incoming 不显示
        if !message.isOutgoing {
            EmptyView()
        } else {
            switch message.status {
            case .sending:
                ProgressView().controlSize(.mini).tint(.white.opacity(0.6))
            case .uploading(let progress):
                ProgressView(value: progress).controlSize(.mini).tint(.white.opacity(0.6)).frame(width: 12)
            case .sent:
                Image(systemName: "checkmark")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            case .read:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color(hex: 0x8515FF))
            case .failed:
                Button(action: { onResend(message) }) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(.red)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .refused:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12)).foregroundStyle(.gray)
            }
        }
    }
}

/// 时间分隔条（对齐 H5 `msgItem.vue:195` — 相邻消息时间差 ≥5min 时显示）。
struct ChatTimeSeparator: View {
    let timestamp: Int64
    var body: some View {
        Text(formatted)
            .font(.system(size: 12))
            .foregroundStyle(ChatPalette.timeSeparator)
            .padding(.vertical, 8)
    }

    private var formatted: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = DateFormatter()
        // 今天：只显示时:分；其他：日期
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }
}

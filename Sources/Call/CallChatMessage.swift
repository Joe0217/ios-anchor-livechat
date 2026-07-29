import Foundation

/// 通话公屏消息（对齐 H5 `homeStore.talkListInCall[]`）。
///
/// **数据来源**：
/// - 本地回显：主播输入文字 sendCallText 后立即 push（H5 sendMessage 本地 unshift 语义）
/// - 远端 sysMsg -1：CallStore.handleRemoteText 追加对方文字
/// - 远端 sysMsg 90：appendWaitBonus 时可选追加充值奖励 cell（可选路径）
///
/// **H5 视觉变体**：
/// - default text：黑色 50% 圆角气泡，远端原文与翻译分两行
/// - custom text：`chatBubble` 九宫格背景，保留原文并在翻译完成后追加译文
/// - gift：与直播公屏一致的 22pt 礼物图与数量
///
/// `Sender` 保留通话信令元信息，但通话公屏只消费 `isSelf` 与 `chatBubble`。
struct CallChatMessage: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let sender: Sender
    let payload: Payload

    struct Sender: Equatable {
        /// 发送方昵称（用于通话外消息链路；通话公屏显示本端/远端语义标签）。
        var nickname: String
        /// 发送方等级（通话消息协议透传字段，当前 H5 通话公屏不展示）。
        var level: Int?
        /// VIP 标记（通话消息协议透传字段，当前 H5 通话公屏不展示）。
        var isVip: Bool = false
        /// 特殊等级标记（通话消息协议透传字段，当前 H5 通话公屏不展示）。
        var isSpecial: Bool = false
        /// 发送方透传的九宫格气泡 URL（H5 `chatBubble`）。
        var chatBubble: String?
        /// 历史字段；通话公屏颜色改由 `isSelf` 派生，保持与 H5 `user === 'her'` 一致。
        var nicknameColor: NicknameColor = .default
        /// 是否本机主播发的消息（对齐 H5 `user === 'my'`）。
        var isSelf: Bool = false

        enum NicknameColor: Equatable {
            case `default`    // 品牌绿
            case her          // 橙色（对方主播端视角 H5 "her" 语义）
            case special      // 亮粉（SS）
        }

        /// 系统消息（bonus 等）的默认 sender。
        static let system = Sender(nickname: "", level: nil, isVip: false, isSpecial: false)
    }

    enum Payload: Equatable {
        /// 文字消息（可选翻译行）。H5 `content.beforeTranslation` + `content.translated`。
        case text(content: String, translation: String?)
        /// 礼物消息。imageURL 优先 giftSmallImg（H5 messageScroller line 11）。count = giftNum。
        case gift(imageURL: String, count: Int)
        /// 充值 bonus 系统消息（H5 callWaitBonus）；sender.system + 图文胶囊样式。
        case bonus(amount: Int)
    }

    init(id: UUID = UUID(),
         timestamp: Date = Date(),
         sender: Sender,
         payload: Payload) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.payload = payload
    }

    // MARK: - Factory

    static func text(sender: Sender, content: String, translation: String? = nil) -> Self {
        Self(sender: sender, payload: .text(content: content, translation: translation))
    }

    static func gift(sender: Sender, imageURL: String, count: Int) -> Self {
        Self(sender: sender, payload: .gift(imageURL: imageURL, count: count))
    }

    static func bonus(amount: Int) -> Self {
        Self(sender: .system, payload: .bonus(amount: amount))
    }
}

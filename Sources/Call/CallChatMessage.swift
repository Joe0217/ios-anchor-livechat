import Foundation

/// 通话公屏消息（对齐 H5 `homeStore.talkListInCall[]` + 通话设计稿.png 5 变体）。
///
/// **数据来源**：
/// - 本地回显：主播输入文字 sendCallText 后立即 push（H5 sendMessage 本地 unshift 语义）
/// - 远端 sysMsg -1：CallStore.handleRemoteText 追加对方文字
/// - 远端 sysMsg 4：GiftEffectSysMsgRouter 消费 liveCallGift payload 时同步追加礼物 cell
/// - 远端 sysMsg 90：appendWaitBonus 时可选追加充值奖励 cell（可选路径）
///
/// **视觉变体**（CallMessageScroller.messageCell 消费）：
/// | 变体          | 触发字段                                | 样式               |
/// |---|---|---|
/// | default text  | payload=.text + sender 无标记            | 无背景，昵称品牌绿 + 内容白色 |
/// | Lv 徽章       | payload=.text + sender.level != nil       | 浅紫半透明背景 + 星级徽章 |
/// | SS special    | payload=.text + sender.isSpecial=true    | 深紫渐变背景 + 亮粉昵称 |
/// | VIP 花式      | payload=.text + sender.isVip=true         | 金色 VIP 徽章 + Lv 徽章可同存 |
/// | gift          | payload=.gift                             | 礼物图 46pt + `x N` 数字 |
///
/// 消息模型不感知渲染细节；`Sender` 的字段是否存在决定 UI 变体分支。
struct CallChatMessage: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let sender: Sender
    let payload: Payload

    struct Sender: Equatable {
        /// 昵称——展示头显示（"Rola:" 前缀）；空则用 L10n.callSignalLabelUser 兜底。
        var nickname: String
        /// 主播 / 用户等级；有值 → 渲染 Lv.N 星级徽章 + 浅紫半透明背景。
        var level: Int?
        /// VIP 用户 → 渲染金色 VIP 徽章。
        var isVip: Bool = false
        /// levelName == "SS" 等最高档 → 渲染深紫渐变特殊气泡(Angelica 样式)。
        var isSpecial: Bool = false
        /// VIP 用户特有的自定义气泡边框图 URL(H5 `chatBubble` 字段)。
        /// 当前 iOS 未渲染 border-image(Wave 6 backlog),保留字段供未来接入。
        var chatBubble: String?
        /// 昵称色(H5 `user === 'her'` → 橙色,其他 → 绿色)。默认 nil → UI 层按 sender kind 派色。
        var nicknameColor: NicknameColor = .default
        /// 是否本机主播发的消息(对齐 H5 `isSelf`)。true 时 UI 层不显示翻译图标——只翻译对方消息。
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

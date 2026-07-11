import Foundation

/// `ChatMessageContent` 的 UI 派生（H-2 spec §4.2 red team #6：会话列表 lastMessage 归一化）。
///
/// **拆分原因**：`L10n` 依赖 Localizable.strings bundle，不入 HilyTests target
/// —— 主 model 层保持纯 Foundation，UI 派生放本文件（对齐
/// `MessageSessionStore+IdleCleanup.swift` 拆分模式）。
extension ChatMessageContent {

    /// 会话列表 lastMessage 展示归一化。
    /// **触发点**：chat store 发送成功后 emit `MessageSessionStore.update(session)`，
    /// session.lastMessage 用此文本填充（避免"[image]" hardcoded）。
    var previewText: String {
        switch self {
        case .text(let s): return s
        case .image: return L10n.messagePreviewImage
        case .video: return L10n.messagePreviewVideo
        case .audio: return L10n.messagePreviewVoice
        case .systemGift(_, let num): return num > 1 ? "[Gift] x\(num)" : "[Gift]"
        case .missedCall(let kind):
            switch kind {
            case .missed: return "[Missed call]"
            case .canceled: return "[Canceled call]"
            case .rejected: return "[Rejected call]"
            }
        case .systemTip(let text, _): return text.isEmpty ? L10n.messagePreviewUnknown : text
        case .system: return L10n.messagePreviewUnknown
        // H-3 新增 3 case（会话列表 lastMessage 归一化文案）
        case .privateImage: return L10n.messagePreviewPrivatePhoto
        case .privateVideo: return L10n.messagePreviewPrivateVideo
        case .chatTip(_, let text, _): return text.isEmpty ? L10n.messagePreviewUnknown : text
        // 新增 case 兜底（cpRankReward / itemNotice / rewardDiamond / punishmentAppeal / rechargeNotify / systemFallback）
        case .cpRankReward: return L10n.messagePreviewUnknown
        case .itemNotice(_, let itemName, _, _): return itemName.isEmpty ? L10n.messagePreviewUnknown : itemName
        case .rewardDiamond(let demoContent): return demoContent.isEmpty ? L10n.messagePreviewUnknown : demoContent
        case .punishmentAppeal(let text, _): return text.isEmpty ? L10n.messagePreviewUnknown : text
        case .rechargeNotify(let content, _, _): return content.isEmpty ? L10n.messagePreviewUnknown : content
        case .systemFallback(let text): return text.isEmpty ? L10n.messagePreviewUnknown : text
        }
    }
}

import Foundation

/// **Deprecated（v3 2026-07-15）**：派对房公屏渲染分类枚举，v3 已迁移到跨场景 unified
/// [`PublicChatVariant`](../../PublicChat/Model/PublicChatVariant.swift)（17 case 全覆盖）+
/// [`SenderProfile`](../../PublicChat/Model/SenderProfile.swift) 富字段 + 13 个现成 Row 组件。
///
/// 保留空 enum 仅为**避免 pbxproj 重生**（`./bin/regen.sh` 后可删除本文件）；无任何生产端赋值。
/// 单测 `PartyAttachTypeTests` 相关 `toMsgType()` 测试已同步移除。
///
/// **迁移路径**：
/// - `msgType == .text` → `variant = .text(content:, mentions:, translation:, replyToNick:)`
/// - `msgType == .gift` → `variant = .gift(iconURL:, name:, count:)`
/// - `msgType == .welcome` → 主播端不再本地生成欢迎消息（房主本人不需要欢迎自己）
/// - `msgType == .convention` → PartyRoomChatArea 顶部绿字 banner（不进 feed）
@available(*, deprecated, message: "v3 迁移到 UnifiedPublicChatMessage + PublicChatVariant")
enum PartyMsgType: Int {
    case convention = 0
    case text = 1
    case gift = 2
    case welcome = 3
}

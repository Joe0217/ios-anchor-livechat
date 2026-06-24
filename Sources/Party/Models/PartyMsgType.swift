import Foundation

/// 派对房公屏渲染分类（对齐安卓 `PartyRoomMsgType`，spec §1.0.2 第 8 条解耦原则）。
///
/// 与 `PartyAttachType` 解耦：
/// - 网络层：`PartyAttachType` 决定信令解码路径
/// - UI 层：`PartyMsgType` 决定公屏气泡渲染模板
/// 两者通过 `PartyAttachType.toMsgType()` 显式映射，**不混为一谈**。
///
/// MVP 仅 0-3 四类；F 期再扩 4-16（管理员变动 / 申请上麦开关 / 切模板 / 游戏中奖 /
/// 活动中奖 / 视频位邀请接受 / PK / 房间通告 / LuckyNumber）。
enum PartyMsgType: Int {
    case convention = 0   // 公约
    case text = 1         // 文本消息（公屏聊天）
    case gift = 2         // 礼物消息
    case welcome = 3      // 进房欢迎
}

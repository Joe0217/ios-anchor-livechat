import Foundation

/// Flame tab 顶部 3 系统消息入口的归一化 model（H-1c 系统消息 3 入口）。
///
/// **3 类固定入口**（对齐 H5 `list.vue:264-345`）：
/// - `.station` — 站内信（来源：HTTP `apiGetStationList`，取 top 1）
/// - `.notification` — 系统通知（来源：NIM P2P session，yxAccId=`AppConfig.notificationYxAccId`）
/// - `.admin` — 客服（来源：NIM P2P session，yxAccId 由 `CustomerServiceIdStore` 提供）
///
/// **UI 定位**：Flame page LazyVStack 顶部前置固定 3 row（无关分类过滤 / 排序，永远显示）。
struct SystemInboxEntry: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case station
        case notification
        case admin
    }

    let id: String
    let kind: Kind
    /// 预览文案：station=mailTitle / notification=lastMessage / admin=lastMessage
    let preview: String
    /// 毫秒时间戳；0 表示无消息（UI 隐藏时间显示）
    let updateTime: Int64
    /// 未读数：station=0/1（本地 UserDefaults 判定）/ notification/admin=SDK unreadCount
    let unread: Int
}

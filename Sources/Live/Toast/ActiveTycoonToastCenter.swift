import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "ActiveTycoonToast")

/// 活跃大 R 进房 Toast 中心 · 对齐 H5 §9.6 `handleActiveTycoonEnterToast`（live.js:713–739）。
///
/// **触发链路**：
/// - IM `attachTypeStr = "active_tycoon_enter_room"` → `AttachType.activeTycoonEnter`
/// - NIMChatroomManager 收到该消息后调 `trigger(userId:isHost:isStreaming:)`
/// - 前置守卫：`isHost && isStreaming`（H5 铁律：仅主态主播开播中才弹）
/// - 去重：同 userId 当天 + 当前主账号内只弹一次（跨天/跨账号 reset）
/// - 视觉：走 [`AppToastCenter`](../../Core/UI/AppToastCenter.swift) 顶部胶囊 Toast，
///   文案 `L10n.liveActiveTycoonEnterToast`
///
/// **持久化**：`UserDefaults` key `live.activeTycoon.toastDedup.<uid>`
/// - 值：`[String]` 已提示的 `"userId_yyyy-MM-dd"` 列表
/// - **多账号隔离**：key 嵌入 `SessionStore.shared.user?.userId`；`logout()` 清 in-memory
/// - 冷启动加载时自动 GC 掉 `>2 天`前的条目，避免内存/UserDefaults 长期增长
@MainActor
final class ActiveTycoonToastCenter {
    static let shared = ActiveTycoonToastCenter()

    private var dedup: Set<String> = []
    private var loadedForUid: Int? = nil

    private init() {}

    /// 主入口：接收 `active_tycoon_enter_room` 消息后调。
    /// - Parameters:
    ///   - userId: 大 R 用户 id（`data.userId` / `data.sendUserId` 双兜底 String）
    ///   - isHost: 当前是否本主播房间（对齐 H5 `isHost` 门禁）
    ///   - isStreaming: 当前是否开播中（对齐 H5 `isStreaming` 门禁）
    func trigger(userId: String, isHost: Bool, isStreaming: Bool) {
        guard isHost, isStreaming else {
            logger.debug("trigger skipped: isHost=\(isHost, privacy: .public) streaming=\(isStreaming, privacy: .public)")
            return
        }
        guard !userId.isEmpty else {
            logger.warning("trigger skipped: empty userId")
            return
        }
        ensureLoaded()

        let key = "\(userId)_\(Self.todayKey())"
        if dedup.contains(key) {
            logger.debug("trigger dedup hit key=\(key, privacy: .private)")
            return
        }
        dedup.insert(key)
        persist()

        // v24 B1（对齐 H5 live.js:738 `duration: 3000`）：显式 3s，AppToastCenter 默认 2s 偏短
        AppToastCenter.shared.show(L10n.liveActiveTycoonEnterToast, duration: 3_000_000_000)
        logger.info("toast shown for userId=\(userId, privacy: .private) date=\(Self.todayKey(), privacy: .public)")
    }

    /// SessionStore.logout 时调；清 in-memory dedup（磁盘由 SessionStore 换号后下次 ensureLoaded 走新 key）
    func clear() {
        dedup.removeAll()
        loadedForUid = nil
    }

    // MARK: - Persistence

    private func storageKey() -> String {
        let uid = SessionStore.shared.user?.userId.map { String($0) } ?? "anon"
        return "live.activeTycoon.toastDedup.\(uid)"
    }

    private func ensureLoaded() {
        let currentUid = SessionStore.shared.user?.userId
        if loadedForUid != currentUid {
            dedup.removeAll()
            loadedForUid = currentUid
            let arr = UserDefaults.standard.stringArray(forKey: storageKey()) ?? []
            // GC >2 天前条目（避免长期跑越攒越多）
            let today = Self.todayKey()
            let yesterday = Self.dateKey(daysAgo: 1)
            let kept = arr.filter { entry in
                guard let dash = entry.range(of: "_") else { return false }
                let date = String(entry[dash.upperBound...])
                return date == today || date == yesterday
            }
            dedup = Set(kept)
            if kept.count != arr.count {
                UserDefaults.standard.set(Array(dedup), forKey: storageKey())
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(Array(dedup), forKey: storageKey())
    }

    // MARK: - Date keys

    /// yyyy-MM-dd 按 Asia/Shanghai（H5 蓝本+安卓一致，H 里程碑 rule 明示业务日期用 UTC+8 固定时区）
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func todayKey() -> String {
        dateFormatter.string(from: Date())
    }

    private static func dateKey(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return dateFormatter.string(from: date)
    }
}

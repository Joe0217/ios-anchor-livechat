import Foundation

/// P2P 会话三分类（H-2 v2 对齐 H5 filter 独立语义）。
///
/// **H5 filter 语义**（`src/stores/modules/session.js:130-167`）：
/// - `filterSessionsByFlame`：ext 通道 A **OR** flameUserIdSet（关注列表）
/// - `filterSessionsByPrimeLevelLimit`：只看 primeUidSet，**不排除 Flame**
/// - `filterSessionsByStranger`：只排除 Flame，**不排除 Prime**
///
/// **关键差异对齐 iOS**（H-1 曾误做单归一 Flame>Prime>Stranger，H-2 v2 修正）：
/// - Prime 与 Flame **可重叠**（同一会话可能同时在两个 tab）
/// - Stranger 可能含 Prime 用户（H5 语义如此）
enum MessageSessionCategory: String, Equatable, CaseIterable {
    /// 火热：ext 通道 A `receivedGift/called/received&&sended` **OR** 关注列表命中
    case flame
    /// 优质：`apiBatchQueryYxPrimeFilter` 命中（**不排除 Flame**）
    case prime
    /// 陌生：不在 Flame（**不排除 Prime**）
    case stranger
}

/// 会话分类决策（pure，可入 HilyTests）。
///
/// **v7 对齐安卓 `MsgMainFragment.isFlame()`（9 条判据）**：
///
/// | 安卓 # | 条件 | iOS 实现 |
/// |---|---|---|
/// | #1 | STATION_YXACC_ID | Store 层 excludedSystemIds 分离到 SystemInboxEntry |
/// | #2 | isSysMsg (notification) | 同上 |
/// | #3 | 客服 | 同上 |
/// | #4 | profile.followed | flameUserIdSet（getFriends type=3） |
/// | #5 | profile.activeTycoon | profiles[sid]?.activeTycoon |
/// | #6 | ext.activeTycoon 兜底 | session.ext.activeTycoon |
/// | #7 | ext.receivedGift | session.ext.receivedGift |
/// | #8 | ext.called | session.ext.called |
/// | #9 | ext.received && ext.sended | boolean AND |
///
/// **Prime / Flame 不互斥**：同一会话可同时命中（对齐安卓 + H5）
enum MessageSessionClassifier {

    /// Flame：ext 通道 A / 关注列表通道 B / profile.activeTycoon 通道 C（对齐安卓 #4-9）
    /// - Parameter profileActiveTycoon: `conversationProfile.activeTycoon`（安卓 #5，服务端身份标签）
    static func isFlame(_ session: MessageSession,
                        flameUserIdSet: Set<String>,
                        profileActiveTycoon: Bool = false) -> Bool {
        // 通道 A: ext (安卓 #6-9)
        if session.ext.isFlameByExt { return true }
        // 通道 B: 关注列表 (安卓 #4)
        if flameUserIdSet.contains(session.id) { return true }
        // 通道 C: profile.activeTycoon (安卓 #5)
        if profileActiveTycoon { return true }
        return false
    }

    /// Prime：primeUidSet 命中（**不排除 Flame**，对齐安卓/H5 —— Prime 与 Flame 可重叠）
    static func isPrime(_ session: MessageSession,
                        primeUidSet: Set<String>) -> Bool {
        primeUidSet.contains(session.id)
    }

    /// Stranger：**只排除 Flame**（对齐安卓/H5：Stranger = !isFlame，不排除 Prime）
    static func isStranger(_ session: MessageSession,
                           flameUserIdSet: Set<String>,
                           profileActiveTycoon: Bool = false) -> Bool {
        !isFlame(session, flameUserIdSet: flameUserIdSet, profileActiveTycoon: profileActiveTycoon)
    }
}

import Foundation

/// P2P 会话三分类（H-1 MVP，H5 `session.js` 分类对齐）。
///
/// **互斥优先级**（spec §1.2）：Flame > Prime > Stranger。
/// 同一 session 同时命中 Flame + Prime → 归 Flame（消费视觉上不重复出现）。
enum MessageSessionCategory: String, Equatable, CaseIterable {
    /// 火热：ext 通道 A 命中（`receivedGift || called || (received && sended)`）
    /// **通道 B**（flameUserIdList / 关注列表并集）scope 排除留 H-2，见 R-6
    case flame
    /// 陌生：既不 Flame 也非 Prime
    case stranger
    /// 优质：`apiBatchQueryYxPrimeFilter` 返回集合命中
    case prime
}

/// 会话分类决策（pure，可入 HilyTests）。
///
/// 决策所需的三态输入：session ext 通道 A + Prime uid 集合 + 后续可扩展 flameUserIdList。
enum MessageSessionClassifier {

    /// 决策入口。
    /// - Parameters:
    ///   - session: 单条会话
    ///   - primeUidSet: 已确认 Prime 的 yxAccid 集合（Prime 拉取结果）
    /// - Returns: 归属分类（互斥优先级 Flame > Prime > Stranger）
    static func classify(_ session: MessageSession, primeUidSet: Set<String>) -> MessageSessionCategory {
        if session.ext.isFlameByExt { return .flame }
        if primeUidSet.contains(session.id) { return .prime }
        return .stranger
    }

    /// 批量分类（内部循环 classify 单条；调用方常用便利）。
    static func classifyAll(_ sessions: [MessageSession], primeUidSet: Set<String>)
        -> [MessageSessionCategory: [MessageSession]] {
        var buckets: [MessageSessionCategory: [MessageSession]] = [
            .flame: [], .stranger: [], .prime: [],
        ]
        for session in sessions {
            let cat = classify(session, primeUidSet: primeUidSet)
            buckets[cat, default: []].append(session)
        }
        return buckets
    }
}

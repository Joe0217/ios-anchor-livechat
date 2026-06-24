import Foundation

/// G 里程碑 spec §2.6：PKStore 状态变化的弱引用观察者。
///
/// 主要订阅方：
/// - `LiveRoomView` 同步 PK 状态到 UI 装配（M3 起接入）
/// - `H` 礼物全景里程碑监听 `didEndPK` 触发礼物动画队列重排
///
/// 全部方法默认空实现，订阅方按需覆盖。
@MainActor
protocol PKStoreObserver: AnyObject {
    func pkStore(_ store: PKStore, didChange state: PKStateMain)
    func pkStore(_ store: PKStore, didUpdateScores scores: PKScoreUpdate)
    func pkStore(_ store: PKStore, didEnterPunishing ctx: PKContext)
    func pkStore(_ store: PKStore, didEndPK finalScores: PKScoreUpdate?)
}

extension PKStoreObserver {
    func pkStore(_ store: PKStore, didChange state: PKStateMain) {}
    func pkStore(_ store: PKStore, didUpdateScores scores: PKScoreUpdate) {}
    func pkStore(_ store: PKStore, didEnterPunishing ctx: PKContext) {}
    func pkStore(_ store: PKStore, didEndPK finalScores: PKScoreUpdate?) {}
}

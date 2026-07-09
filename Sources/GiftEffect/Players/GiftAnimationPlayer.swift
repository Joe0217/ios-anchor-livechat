import UIKit

@MainActor
public protocol GiftAnimationPlayer: AnyObject {
    /// 播放一段动画；onFinish 由播放器在**主线程**回调（幂等，被 stop 硬打断时也应 fire 一次）
    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void)
    /// 硬停：立即中断当前播放并清理，onFinish 会（同步或异步）被调一次
    func stop()
    /// SDK 实例销毁（logout 时调）
    func tearDown()
}

/// 默认路由抽象（Task 5 加两个具体 player 后 impl）
@MainActor
public protocol GiftPlayerRouting: AnyObject {
    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void)
    func stopAll()
    func tearDownPlayers()
    func warmupSVGA()
}

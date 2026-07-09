import UIKit
// 待测源码通过 project.yml HilyTests.sources 编入 HilyTests module；无需 @testable import Hily

@MainActor
final class FakeGiftPlayerRouter: GiftPlayerRouting {
    var playHistory: [GiftEffectItem] = []
    var stopAllCount = 0
    var tearDownCount = 0
    var warmupCount = 0
    /// 若 true，play 时不立即 fire onFinish，需外部调 `finishCurrent()`（模拟真异步）
    var manualFinish = false
    private var pendingFinish: (() -> Void)?

    func play(item: GiftEffectItem, in host: UIView, onFinish: @escaping () -> Void) {
        playHistory.append(item)
        if manualFinish {
            pendingFinish = onFinish
        } else {
            onFinish()
        }
    }
    func finishCurrent() {
        let f = pendingFinish
        pendingFinish = nil
        f?()
    }
    func stopAll() {
        stopAllCount += 1
        let f = pendingFinish
        pendingFinish = nil
        f?()   // 硬停也 fire onFinish 一次（对齐 spec §5.3 幂等保护）
    }
    func tearDownPlayers() { tearDownCount += 1 }
    func warmupSVGA() { warmupCount += 1 }
}

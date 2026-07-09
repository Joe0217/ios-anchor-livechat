import Foundation

/// 送礼动画播放器 protocol —— 供 GiftAnimationOverlay 抽象调用，
/// 允许 H 里程碑 replace `StubGiftAnimationPlayer` 为真 `SVGAPlayer-iOS` / `Lottie` 实现
protocol GiftAnimationPlayerProtocol {
    /// 播放一段动画
    /// - Parameters:
    ///   - url: SVGA/MP4 资源 URL（v8 Fakes 忽略，用固定时长模拟）
    ///   - onFinish: 播放完成回调（Overlay 用于队列 shift 下一条）
    func play(url: String?, onFinish: @escaping () -> Void)
}

/// v8 Stub 实现 —— 2.5s Task.sleep 模拟播放；不真渲染 SVGA，只用 GiftAnimationOverlay 视觉容器占位
struct StubGiftAnimationPlayer: GiftAnimationPlayerProtocol {
    func play(url: String?, onFinish: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            onFinish()
        }
    }
}

/// H 里程碑真 SVGA 实现骨架
///
/// TODO H 礼物会话：
/// - 引入 SVGAPlayer-iOS Pod 依赖（对齐 xcodegen-podinstall-binding rule 流程）
/// - 用 `SVGAParser().parse(with: URL)` 下载 + 解析
/// - `SVGAPlayer` 单例挂 UIView（GiftAnimationOverlay 内层）
/// - `didFinishedAnimation` delegate 回调 → onFinish
struct RealSVGAPlayer: GiftAnimationPlayerProtocol {
    func play(url: String?, onFinish: @escaping () -> Void) {
        // TODO H 里程碑：接入真 SVGA 播放
        StubGiftAnimationPlayer().play(url: url, onFinish: onFinish)
    }
}

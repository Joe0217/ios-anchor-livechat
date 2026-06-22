import MetalKit
import CoreImage
import CoreVideo
import UIKit

/// 用 Metal + Core Image 渲染 CVPixelBuffer 的预览视图。
///
/// 关键：相芯美颜处理后返回的同样是 CVPixelBuffer，走的就是这条渲染路径，
/// 所以第二阶段接入美颜时，本视图无需任何改动。
///
/// **v5.3 后台/前台修复**（用户反馈"切后台回来画面卡住"根因）：
/// - 切后台：iOS 暂停 CADisplayLink + 释放 CAMetalDrawable；didEnterBackground 主动 releaseDrawables
/// - 回前台：延迟 300ms 等 CAMetalLayer 完全 attach 后 setNeedsDisplay 才能拿到有效 drawable
///
/// **v5.3.1 review 修订**：
/// - data race：render 改为 main queue 写 currentImage（原 background queue 写 + main queue 读 + ARC 不安全）
/// - 鬼影：didEnterBackground 清空 currentImage 避免回前台先闪一帧旧画面
/// - 重入：pendingForegroundDraw 可 cancel 的 DispatchWorkItem，didEnterBackground 时取消
final class MetalPreviewView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    /// 仅 main queue 读写（v5.3.1 修 data race）
    private var currentImage: CIImage?
    /// 可取消的前台首帧绘制任务（v5.3.1 修双切场景：300ms 内再次后台时 cancel 避免 drawable 仍 nil 时 setNeedsDisplay 空跑）
    private var pendingForegroundDraw: DispatchWorkItem?

    init(device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = dev.makeCommandQueue()!
        self.ciContext = CIContext(mtlDevice: dev)
        super.init(frame: .zero, device: dev)
        framebufferOnly = false          // Core Image 需要可写纹理
        colorPixelFormat = .bgra8Unorm
        isPaused = true                  // 按帧驱动，不用内部 60fps 循环
        enableSetNeedsDisplay = true
        contentMode = .scaleAspectFill
        addLifecycleObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingForegroundDraw?.cancel()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 后台/前台生命周期（v5.3 / v5.3.1）

    private func addLifecycleObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleDidEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleWillEnterForeground),
                       name: UIApplication.willEnterForegroundNotification,
                       object: nil)
    }

    @objc private func handleDidEnterBackground() {
        // 取消可能 pending 的前台首帧绘制（双切场景）
        pendingForegroundDraw?.cancel()
        pendingForegroundDraw = nil
        // v5.3.5：撤销 v5.3.4 的"不闪烁"修复，恢复 v5.3.1 行为清空 currentImage
        // 闪烁版与不闪烁版的本质都是 AVCaptureSession 重启 1-2s 等待期：
        //   - 清空：1-2s 黑屏 → 真实画面（短暂明确闪烁，用户视觉感知"app 重连中"）
        //   - 不清空：1-2s 旧帧停留 → 真实画面（视觉像"画面卡住"，用户误判）
        // 经用户反馈"不介意闪烁"，恢复闪烁版让重连感更明确，避免误判为 bug
        currentImage = nil
        // MTKView 官方推荐：主动释放 drawable GPU 资源
        releaseDrawables()
    }

    @objc private func handleWillEnterForeground() {
        // 取消旧 pending 任务（重复切后台/前台）
        pendingForegroundDraw?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 守卫：300ms 内若再次进入 background，applicationState 已变，避免 drawable nil 时 setNeedsDisplay 空跑
            guard UIApplication.shared.applicationState == .active else { return }
            self.setNeedsDisplay()
        }
        pendingForegroundDraw = work
        // 延迟 300ms 等 CAMetalLayer 完全 attach 到 window scene（实测 iOS 17 上 100ms 内，留余量）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - 渲染

    /// 提交一帧到预览。v5.3.1 修 data race：CIImage 创建 + 写 currentImage + setNeedsDisplay 全 main queue 串行
    func render(_ pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentImage = CIImage(cvPixelBuffer: pixelBuffer)
            self.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let image = currentImage,
              let drawable = currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }

        let size = drawableSize
        // aspectFill：等比放大铺满并居中
        let scale = max(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let tx = (size.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let ty = (size.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        let centered = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        ciContext.render(centered,
                         to: drawable.texture,
                         commandBuffer: buffer,
                         bounds: CGRect(origin: .zero, size: size),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        buffer.present(drawable)
        buffer.commit()
    }
}

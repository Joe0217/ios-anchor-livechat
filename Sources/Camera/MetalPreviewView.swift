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
/// - 重入：pendingForegroundDraw 可 cancel 的 DispatchWorkItem，didEnterBackground 时取消
///
/// **v5.5 反悔 v5.3.5（Bug C 修复）**：
/// - 切后台保留 currentImage 作为最后一帧占位（不清空），回前台 setNeedsDisplay 立刻渲染最后一帧
/// - 真新帧（AVCaptureSession 重启 1-2s 后到达）通过 render(_:) 自然替换，视觉无空窗黑屏
/// - v5.3.5 注释里写"用户不介意闪烁"是当时错误判断，实测反馈"卡死"——决策反悔
final class MetalPreviewView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    /// 仅 main queue 读写（v5.3.1 修 data race）
    private var currentImage: CIImage?
    /// 可取消的前台首帧绘制任务（v5.3.1 修双切场景：300ms 内再次后台时 cancel 避免 drawable 仍 nil 时 setNeedsDisplay 空跑）
    private var pendingForegroundDraw: DispatchWorkItem?
    /// Party 视频位使用：等比放大到填满容器，并从中心裁剪溢出区域。
    var forceAspectFill = false {
        didSet {
            if oldValue != forceAspectFill {
                setNeedsDisplay()
            }
        }
    }

    init(device: MTLDevice?) {
        // 项目仅 iPhone iOS 16+，所有目标设备均支持 Metal——理论上不会失败；
        // 仍以 guard + fatalError 替代裸 `!`，失败时错误信息明确而非裸 Optional trap。
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
            fatalError("Metal device unavailable — Hily requires iPhone with Metal support")
        }
        guard let queue = dev.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue on \(dev.name)")
        }
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: dev)
        super.init(frame: .zero, device: dev)
        framebufferOnly = false          // Core Image 需要可写纹理
        colorPixelFormat = .bgra8Unorm
        isPaused = true                  // 按帧驱动，不用内部 60fps 循环
        enableSetNeedsDisplay = true
        contentMode = .scaleAspectFill
        // aspectFit 触发时上下留出的区域用 liveBottomDark（#0B0010 近黑紫）填充，
        // 与 LiveRoomView 底色一致 → PK 缩小场景视觉融合，避免明显黑边割裂
        clearColor = MTLClearColor(red: 0x0B / 255.0, green: 0x00 / 255.0,
                                   blue: 0x10 / 255.0, alpha: 1)
        layer.backgroundColor = UIColor(red: 0x0B / 255.0, green: 0x00 / 255.0,
                                        blue: 0x10 / 255.0, alpha: 1).cgColor
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
        // v5.5 反悔 v5.3.5："清空 currentImage 让闪烁更明确"实测用户反馈是"卡死"。
        // 现策略：保留最后一帧作占位，回前台 setNeedsDisplay 立刻渲染最后一帧 →
        //   真新帧（AVCaptureSession startRunning 1-2s 后到达）自然替换，视觉无空窗
        // 不再 currentImage = nil；仅释放 drawable GPU 资源（MTKView 官方推荐）。
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
        // aspectFill / aspectFit 自适应（2026-07-06 修 PK 半屏视频画面裁剪根因）：
        // 当 drawable 宽高比与原图偏差 >50% 时切 aspectFit（保留完整帧），否则 aspectFill 铺满。
        // 触发场景：PK 中 SwiftUI `.frame(width: 187, height: 300)` 让 drawable 变小，
        // 原始 1280×720 帧按 aspectFill 会大幅裁剪显示"半个人头" → 阈值切 fit 后完整显示。
        // aspectFit 上下留出区域由 layer.backgroundColor (liveBottomDark) 填充，与整体背景融合。
        //
        // ⚠️ **隐式假设** (2026-07-07 code review 建议-2 沉淀)：本阈值 0.5 依赖 CameraManager 输出
        //   pixel buffer 是**竖屏 orientation**（约 720×1280，imgAspect ≈ 0.56）。当前验证：
        //   - 非 PK 全屏 iPhone (390×844, drawAspect 0.46) vs pixel buffer (720×1280) → delta ~22% <50% → aspectFill 无黑边 ✓
        //   - PK 半屏 (187×300, drawAspect 0.62) vs pixel buffer (720×1280) → delta ~65% >50% → 触发 aspectFit ✓
        //   **若未来 CameraManager refactor 改为横屏输出**（1280×720, imgAspect ≈ 1.78），全屏场景 delta
        //   会剧增到 285% → 误触发 aspectFit → 全屏出现大面积背景色（视觉回归）。**需回归验证**。
        let imgAspect = image.extent.width / image.extent.height
        let drawAspect = size.width / size.height
        let aspectDelta = abs(imgAspect - drawAspect) / min(imgAspect, drawAspect)
        let useFit = !forceAspectFill && aspectDelta > 0.5
        let scale = useFit
            ? min(size.width / image.extent.width, size.height / image.extent.height)  // aspectFit 留背景色
            : max(size.width / image.extent.width, size.height / image.extent.height)  // aspectFill 铺满
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

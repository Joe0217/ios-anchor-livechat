import MetalKit
import CoreImage
import CoreVideo

/// 用 Metal + Core Image 渲染 CVPixelBuffer 的预览视图。
///
/// 关键：相芯美颜处理后返回的同样是 CVPixelBuffer，走的就是这条渲染路径，
/// 所以第二阶段接入美颜时，本视图无需任何改动。
final class MetalPreviewView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private var currentImage: CIImage?

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
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 提交一帧到预览
    func render(_ pixelBuffer: CVPixelBuffer) {
        currentImage = CIImage(cvPixelBuffer: pixelBuffer)
        DispatchQueue.main.async { [weak self] in self?.setNeedsDisplay() }
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

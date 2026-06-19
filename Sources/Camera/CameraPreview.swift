import SwiftUI
import MetalKit

/// 把 MetalPreviewView 桥接进 SwiftUI。相机每帧（已美颜）：
/// 1) 本地预览渲染（Metal）
/// 2) 若传入 agora，则推给声网编码推流（自定义视频源）；预览场景可不传 agora。
struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager
    var agora: AgoraManager? = nil

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView(device: MTLCreateSystemDefaultDevice())
        let agora = self.agora
        camera.onFrame = { [weak view] pixelBuffer in
            view?.render(pixelBuffer)
            agora?.pushFrame(pixelBuffer)
        }
        return view
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {}
}

import SwiftUI
import MetalKit

/// 把 MetalPreviewView 桥接进 SwiftUI。相机每帧（已美颜）：
/// 1) 本地预览渲染（Metal）
/// 2) 若传入 agora，则推给声网编码推流（自定义视频源）；预览场景可不传 agora。
///
/// **v5.3.3 关键修复**：onFrame 绑定**必须**在 updateUIView 兜底重绑。
/// 根因：v5.3.1 `LiveRoomView.onDisappear` 内 `camera.tearDown()` 会清空 `onFrame=nil`；
/// 而 SwiftUI 在 ScenePhase=.background 时**也会**触发 onDisappear（snapshot 用），
/// 切后台→回前台后 SwiftUI 复用 @StateObject camera + UIView 实例，只走 updateUIView 不走 makeUIView，
/// 若 updateUIView 不重新绑定 onFrame，则推流帧链路永久断开，引发画面卡 + 推流断 + 60s 后 forceEnd(.weakNetwork)。
struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager
    var agora: AgoraManager? = nil

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView(device: MTLCreateSystemDefaultDevice())
        bindFrameSink(to: view)
        return view
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {
        // v5.3.3 兜底重绑：onFrame 被 tearDown 清空后，下次 SwiftUI body re-evaluate 时恢复链路
        if camera.onFrame == nil {
            bindFrameSink(to: uiView)
        }
    }

    private func bindFrameSink(to view: MetalPreviewView) {
        let agoraRef = self.agora
        camera.onFrame = { [weak view, weak agoraRef] pixelBuffer in
            view?.render(pixelBuffer)
            agoraRef?.pushFrame(pixelBuffer)
        }
    }
}

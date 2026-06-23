import SwiftUI
import MetalKit

/// 把 MetalPreviewView 桥接进 SwiftUI。相机每帧（已美颜）：
/// 1) 本地预览渲染（Metal）
/// 2) 若传入 agora，则推给声网编码推流（自定义视频源）；预览场景可不传 agora。
///
/// ## v5.8 订阅字典方案（替代 v5.3.3 ~ v5.7 的单闭包覆盖思路）
///
/// **历史失败方案**：
/// - v5.3.3 ~ v5.6：`updateUIView` 守 `onFrame == nil` 才 bindFrameSink。直播私 call 挂断后
///   闭包内 weak view 已 nil 但**闭包本身仍非 nil**，守卫不通过 → 本端永久断流
/// - v5.7：去掉守卫，`updateUIView` 每次强制重绑。直播私 call 场景里 LiveRoomView 本体的
///   CameraPreview 在 ZStack 主层、CallView overlay 在 `.overlay { ... }` 修饰内——
///   SwiftUI 在 overlay 内 view 消失时**不会**触发 ZStack 兄弟节点的 updateUIView
///   （本体 view tree 位置未变、prop 未变，SwiftUI 没有理由 re-call），本体永远拿不到
///   重绑机会 → 本端画面卡死 + 观众端断流（用户实测复现）
///
/// **v5.8 真根因 + 修复**：
/// 单闭包模型本质不支持"同一 CameraManager 多个并行下游"。直播私 call 期间本体（推直播 Agora）+
/// PIP（推通话 Agora）同时需要帧，必须用订阅字典：每个 CameraPreview 持有独立 Coordinator key，
/// PIP 在 dismantleUIView 时**精确注销自己那一格**，本体的 sink 始终留在字典里——不依赖任何
/// SwiftUI re-eval 时机，杜绝 v5.3.3 ~ v5.7 的所有调度盲点。
struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager
    var agora: AgoraManager? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: camera)
    }

    func makeUIView(context: Context) -> MetalPreviewView {
        let view = MetalPreviewView(device: MTLCreateSystemDefaultDevice())
        context.coordinator.attach(view: view, agora: agora)
        return view
    }

    func updateUIView(_ uiView: MetalPreviewView, context: Context) {
        // v5.8：updateUIView 也 attach，覆盖 agora 引用可能变化的情况（例：CallView 重建 store.agora）。
        // 字典 set 同 key 是幂等的（覆盖闭包，不再 race；订阅字典本身就承担去重）。
        context.coordinator.attach(view: uiView, agora: agora)
    }

    static func dismantleUIView(_ uiView: MetalPreviewView, coordinator: Coordinator) {
        // v5.8 关键：PIP CameraPreview 销毁时（CallView overlay 移除），精准注销自己那一格订阅。
        // LiveRoomView 本体的 Coordinator 不受影响，sink 继续留在 camera.subscribers 字典里。
        coordinator.detach()
    }

    /// Coordinator 与每个 CameraPreview view 实例一一对应；ObjectIdentifier(coordinator) 作为
    /// CameraManager.subscribers 字典的 key——独立于 view 实例，独立于闭包，独立于 SwiftUI 调度时机。
    final class Coordinator {
        private weak var camera: CameraManager?
        private var subscribedKey: ObjectIdentifier?

        init(camera: CameraManager) {
            self.camera = camera
        }

        deinit {
            detach()
        }

        func attach(view: MetalPreviewView, agora: AgoraManager?) {
            guard let camera else { return }
            let myKey = ObjectIdentifier(self)
            let agoraRef = agora
            camera.subscribe(myKey) { [weak view, weak agoraRef] pixelBuffer in
                view?.render(pixelBuffer)
                agoraRef?.pushFrame(pixelBuffer)
            }
            subscribedKey = myKey
        }

        func detach() {
            if let key = subscribedKey, let camera {
                camera.unsubscribe(key)
            }
            subscribedKey = nil
        }
    }
}

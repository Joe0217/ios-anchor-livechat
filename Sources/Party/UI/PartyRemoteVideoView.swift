import SwiftUI
import UIKit

/// 把派对房远端麦位的渲染 UIView 桥接进 SwiftUI（spec v4 §4）。
///
/// **稳定性约束**（rules `swiftui-camera-preview.md` §2）：
/// AgoraRtcVideoCanvas.view 是声网 SDK 持外部强引用的 UIView，反复 makeUIView 会丢首帧。
/// 解决：UIView 实例由 `PartyRTCEngine` 按 seatIndex 维池稳定持有；本 representable 仅取池实例。
/// `updateUIView` 留空 —— UIView 实例不变，无需任何属性更新。
struct PartyRemoteVideoView: UIViewRepresentable {
    let seatIndex: Int
    let engine: PartyRTCEngine

    func makeUIView(context: Context) -> UIView {
        let view = engine.acquireRemoteView(seatIndex: seatIndex)
        // 视频填充+等比裁剪由 `AgoraRtcVideoCanvas.renderMode=.hidden` 在
        // `PartyRTCEngine.setupRemoteVideo` 内控制；SDK 底层是 GLKView/MTKView，UIView.contentMode
        // 对其无效（Agora 内部 subview 自绘）。此处只保留 `clipsToBounds` 兜底防 SDK subview 溢出边界。
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 池中实例稳定；持续保证 SDK 子视图不会溢出当前视频位容器。
        uiView.clipsToBounds = true
    }
}

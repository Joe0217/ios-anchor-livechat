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
        // 视频填充满 seat + 超出裁剪（aspect fill + clipped）—— 用户 2026-07-14 requirement：
        // AgoraRtcVideoCanvas.renderMode=.hidden 已在 PartyRTCEngine.setupRemoteVideo 设为等比裁剪；
        // 此处 UIView layer 加 masksToBounds=true 双保险，防 SDK 内部 subview 超出边界溢出
        view.clipsToBounds = true
        view.contentMode = .scaleAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // no-op：池中实例稳定，无需更新
    }
}

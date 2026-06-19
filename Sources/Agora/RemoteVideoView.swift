import SwiftUI
import UIKit

/// 把声网远端渲染用的 UIView 桥接进 SwiftUI。
struct RemoteVideoView: UIViewRepresentable {
    let manager: AgoraManager

    func makeUIView(context: Context) -> UIView { manager.remoteView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

import SwiftUI

public extension View {
    /// 声明本 view 属于某个礼物特效场景
    ///
    /// - onAppear 时 setActiveScene（若 activeKey 不同则触发硬中断切场景）
    /// - onDisappear 时 leaveScene（scenePhase != .background 守卫，避免切后台误清）
    ///
    /// - Parameters:
    ///   - scene: 场景类型 .live / .call / .party / .chat
    ///   - scopeId: 场景内唯一标识（liveRoomId / callId / partyRoomId / peerYxAccid）
    func giftEffectScene(_ scene: GiftEffectScene, scopeId: String) -> some View {
        modifier(GiftEffectSceneModifier(scene: scene, scopeId: scopeId))
    }
}

private struct GiftEffectSceneModifier: ViewModifier {
    let scene: GiftEffectScene
    let scopeId: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                GiftEffectCenter.shared.setActiveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                )
            }
            .onDisappear {
                // 对齐 .claude/rules/swiftui-camera-preview.md §6：
                // iOS 14+ SwiftUI 在 scenePhase=.background 时也触发 onDisappear，
                // 那不是真正的 view 离开，不能清队列
                guard scenePhase != .background else { return }
                GiftEffectCenter.shared.leaveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                )
            }
    }
}

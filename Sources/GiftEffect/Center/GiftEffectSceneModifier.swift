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
    func giftEffectScene(
        _ scene: GiftEffectScene,
        scopeId: String,
        isEnabled: Bool = true
    ) -> some View {
        modifier(GiftEffectSceneModifier(scene: scene, scopeId: scopeId, isEnabled: isEnabled))
    }
}

private struct GiftEffectSceneModifier: ViewModifier {
    let scene: GiftEffectScene
    let scopeId: String
    let isEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard isEnabled else { return }
                GiftEffectCenter.shared.setActiveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                )
            }
            // 同一 View 实例切到另一房间/通话时不一定会重新触发 onAppear；
            // scope 改变必须立即硬中断旧场景并清空其队列。
            .onChange(of: scopeId) { newScopeId in
                guard isEnabled else { return }
                GiftEffectCenter.shared.replaceActiveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: newScopeId)
                )
            }
            // 保持 content 身份不变，避免权限热切换把承载这个 modifier 的房间根视图误判为离场。
            .onChange(of: isEnabled) { enabled in
                let key = GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                if enabled {
                    GiftEffectCenter.shared.setActiveScene(key)
                } else {
                    GiftEffectCenter.shared.leaveScene(key)
                }
            }
            .onDisappear {
                // 对齐 .claude/rules/swiftui-camera-preview.md §6：
                // iOS 14+ SwiftUI 在 scenePhase=.background 时也触发 onDisappear，
                // 那不是真正的 view 离开，不能清队列
                guard isEnabled, scenePhase != .background else { return }
                GiftEffectCenter.shared.leaveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                )
            }
    }
}

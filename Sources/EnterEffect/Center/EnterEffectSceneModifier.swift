import SwiftUI

public extension View {
    /// 声明本 view 属于某个进场特效场景
    ///
    /// - onAppear 时 setActiveScene（若 activeKey 不同则触发硬中断切场景）
    /// - onDisappear 时 leaveScene（scenePhase != .background 守卫，避免切后台误清）
    ///
    /// 与 `.giftEffectScene(...)` **并列使用**：两个 modifier 分别驱动 GiftEffectCenter / EnterEffectCenter，
    /// 独立 activeKey/pending 队列，天然并行播放。
    ///
    /// - Parameters:
    ///   - scene: 场景类型 .live / .call / .party / .chat
    ///   - scopeId: 场景内唯一标识（与 giftEffectScene 同源，如 liveRoomId 用 yxRoomId）
    func enterEffectScene(_ scene: GiftEffectScene, scopeId: String) -> some View {
        modifier(EnterEffectSceneModifier(scene: scene, scopeId: scopeId))
    }
}

private struct EnterEffectSceneModifier: ViewModifier {
    let scene: GiftEffectScene
    let scopeId: String
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                EnterEffectCenter.shared.setActiveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                )
            }
            .onDisappear {
                // 对齐 .claude/rules/swiftui-camera-preview.md §6：
                // iOS 14+ SwiftUI 在 scenePhase=.background 时也触发 onDisappear，
                // 那不是真正的 view 离开，不能清队列
                guard scenePhase != .background else { return }
                EnterEffectCenter.shared.leaveScene(
                    GiftEffectSceneKey(scene: scene, scopeId: scopeId)
                )
            }
    }
}

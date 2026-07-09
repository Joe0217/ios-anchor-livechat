import SwiftUI

/// 通用顶部提示气泡（对齐 H5 liveRoom.vue L720-732 3 个 tip 气泡）
///
/// 用法：
/// ```
/// @State private var showTip: Bool = true
/// // ...
/// LiveRoomTipBubble(isPresented: $showTip,
///                   text: L10n.tipToolText,
///                   autoDismissAfter: 5.0)
/// ```
///
/// **auto-dismiss**：`autoDismissAfter` 秒后自动隐藏；tap 也可关闭
struct LiveRoomTipBubble: View {
    @Binding var isPresented: Bool
    let text: String
    /// 自动关闭时长；nil = 手动关闭
    let autoDismissAfter: TimeInterval?

    var body: some View {
        if isPresented {
            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: 0x333333))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 4)
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
            }
            .transition(.opacity.combined(with: .scale))
            .onAppear {
                guard let after = autoDismissAfter else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                }
            }
        }
    }

    /// UserDefaults key 前缀 —— 按 userId scope 首次显示标记
    /// 用法：`UserDefaults.standard.bool(forKey: LiveRoomTipBubble.shownKey(tipId: "tool", userId: uid))`
    static func shownKey(tipId: String, userId: String) -> String {
        "tip.\(tipId).shown.\(userId)"
    }
}

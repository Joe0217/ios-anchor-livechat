import SwiftUI

/// v17 直播中设置弹窗 —— 对齐 H5 `liveSettingPopup.vue` Bottom Sheet + 3 列 Grid
///
/// **H5 参考**（src/views/liveSetting/components/liveSettingPopup.vue）：
/// - Bottom sheet + `rounded-t-16` + 紫色渐变背景 `linear-gradient(240deg, #17175A → #1D0E4C → #130A2A)`
/// - 3 列 Grid，每项 icon 32×32 + label
/// - 已启用：虚拟道具特效开关 / 公告管理
/// - 未启用（H5 注释掉）：音频开关 / 贴纸设置
///
/// **iOS 4 项**（合并了 H5 已启用 + iOS 原有 confirmationDialog 2 项）：
/// - 虚拟道具特效
/// - 公告管理
/// - 美颜
/// - 结束直播（destructive）
struct LiveSettingBottomSheet: View {
    @Binding var isPresented: Bool
    let beautyAvailable: Bool
    let onOpenBeauty: () -> Void
    let onOpenEffects: () -> Void
    let onOpenAnnouncement: () -> Void
    let onEndLive: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            grid
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x17175A), Color(hex: 0x1D0E4C), Color(hex: 0x130A2A)],
                startPoint: .topTrailing, endPoint: .bottomLeading
            )
            .ignoresSafeArea()
        )
    }

    // v20: header (title + X) 已移除，关闭走系统下拉手势
    private var header: some View { EmptyView() }

    private var grid: some View {
        // v20: 移除美颜入口（用户明示直播中不再从设置里进美颜；美颜入口保留在开播前设置页）
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 20) {
            settingCell(icon: "sparkles", label: L10n.liveRoomSettingEffect, tint: .white) {
                isPresented = false
                onOpenEffects()
            }
            settingCell(icon: "megaphone.fill", label: L10n.liveRoomSettingAnnouncement, tint: Color(hex: 0xFFE000)) {
                isPresented = false
                onOpenAnnouncement()
            }
            settingCell(icon: "xmark.circle.fill", label: L10n.liveRoomSettingEndLive, tint: Color(hex: 0xFF4040)) {
                isPresented = false
                onEndLive()
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 20)
    }

    private func settingCell(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundColor(tint)
                    .frame(width: 32, height: 32)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// 首页：直播流广场（Live 设计稿还原）。
///
/// 顶部子 tab Live/List/Match/Cysle 切换由 LiveTabView 自管理。
/// 右下角悬浮按钮触发 POC 调试台，方便真机自测；上线前删除。
struct HomeView: View {
    @State private var showPOC = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            LiveTabView()
            pocFloatingButton
                .padding(.trailing, 16)
                .padding(.bottom, 16)
        }
        .sheet(isPresented: $showPOC) {
            POCDebugView()
        }
    }

    /// 临时悬浮入口：仅供开发期访问 POC，与 Live 内容明显区分（不进 Theme，避免污染设计系统）。
    private var pocFloatingButton: some View {
        Button {
            showPOC = true
        } label: {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(Color.black.opacity(0.55))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        // 临时调试入口的中文 a11y label：上线前整个按钮会删除，无需进 L10n
        .accessibilityLabel("POC 调试台")
    }
}

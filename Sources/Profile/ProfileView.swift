import SwiftUI
import UIKit

/// Profile 屏（设计稿还原）。
///
/// 结构：顶部紫色渐变区（含头像/名字/SS/stats） → 描述 → Album/Gifts/Moment tab → Photos/Videos 网格。
/// 设计稿还原阶段使用 ProfileViewModel 占位数据；接入用户接口时由 SessionStore 注入。
///
/// 安全区处理对齐 LiveTabView：背景图独立成 `.background { }` 层并 `ignoresSafeArea(edges: .top)`，
/// content 正常布局不做安全区黑魔法，避免撑爆 ScrollView 宽度 / 吃掉 MainTabView 的 bottom inset。
struct ProfileView: View {
    @StateObject private var vm = ProfileViewModel()

    /// 屏幕顶部 safe area inset（状态栏/刘海高度）。
    /// 工程仅竖屏（CLAUDE.md），不响应屏幕旋转，body 内读一次即可。
    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ProfileHeaderView(vm: vm)

                ProfileBioView(bio: vm.bio)

                ProfileTabBar(selected: $vm.selectedTab)
                    .padding(.top, 4)

                contentForSelectedTab
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { backgroundLayer }
        .preferredColorScheme(.dark)
    }

    /// 整页背景：底色 + 顶部紫色渐变切图（仅顶部段），仅顶端扩到状态栏。
    /// **不**扩到底部，避免覆盖 MainTabView 的 TabBar（对齐 LiveTabView 模式）。
    private var backgroundLayer: some View {
        VStack(spacing: 0) {
            Image("profileTopBg")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Metric.profileHeaderHeight + topSafeAreaInset)
                .overlay(alignment: .bottom) {
                    // 与下方页面底色平滑过渡，避免硬边
                    LinearGradient(
                        colors: [Color.clear, Theme.Palette.profileBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 60)
                }
                .clipped()
            Theme.Palette.profileBackground
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var contentForSelectedTab: some View {
        switch vm.selectedTab {
        case .album:
            VStack(spacing: Theme.Metric.profileGridSectionGap) {
                ProfileMediaGrid(
                    title: String(format: L10n.profilePhotosFormat, vm.photos.count, vm.photosTotal),
                    items: vm.photos
                )
                ProfileMediaGrid(
                    title: String(format: L10n.profileVideosFormat, vm.videos.count, vm.videosTotal),
                    items: vm.videos
                )
            }
        case .gifts:
            emptyPlaceholder
        case .moment:
            emptyPlaceholder
        }
    }

    private var emptyPlaceholder: some View {
        Text(L10n.profileEmptyPlaceholder)
            .font(Theme.Typography.profileDesc)
            .foregroundColor(Theme.Palette.profileTabInactive)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
    }
}

#Preview {
    ProfileView()
}

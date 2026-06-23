import SwiftUI
import UIKit

/// Profile 屏（设计稿还原）。
///
/// 结构：顶部紫色渐变区（含头像/名字/SS/stats） → 描述 → Album/Gifts/Moment tab → Photos/Videos 网格。
/// 设计稿还原阶段使用 ProfileViewModel 占位数据；接入用户接口时由 SessionStore 注入。
///
/// 安全区处理对齐 LiveTabView：背景图独立成 `.background { }` 层并 `ignoresSafeArea(edges: .top)`，
/// content 正常布局不做安全区黑魔法，避免撑爆 ScrollView 宽度 / 吃掉 MainTabView 的 bottom inset。
///
/// 通用规则：navigation path 上抬到 MainTabView 持有（`@Binding var path`），
/// 两段 navigationDestination（FollowSegment / ProfileRoute）也上移到 MainTabView 根节点，
/// 让 tabbar 能感知 Profile 子页 push/pop 深度，做几何坍缩。
/// 媒体预览 sheet 数据载体：MediaAsset + 是否视频。
/// Identifiable 让 fullScreenCover(item:) 能用单一 state 驱动开关。
private struct MediaPreviewContext: Identifiable {
    let asset: MediaAsset
    let isVideo: Bool
    var id: String { "\(asset.id)-\(isVideo ? "v" : "p")" }
}

/// Profile 子页路由枚举。NavigationLink(value:) + navigationDestination(for:) 解耦目标类型。
/// FollowSegment 已是另一个独立 NavigationDestination；本 enum 容纳剩余子页路由。
enum ProfileRoute: Hashable {
    case settings
    case levelDetail
}

struct ProfileView: View {
    @StateObject private var vm = ProfileViewModel()
    @State private var previewContext: MediaPreviewContext?
    @Binding var path: NavigationPath

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
        // 不再自带 NavigationStack：外层 MainTabView 的 NavigationStack(path: $profilePath) 接管。
        // NavigationLink(value:) 自动沿 stack 找匹配 destination，无需在此再注册。
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
        // 状态 banner：仅 error 时出现（loading 由系统下拉刷新自带指示器承担，不再叠 banner）
        .overlay(alignment: .top) {
            statusBanner
                .padding(.top, topSafeAreaInset + 8)
                .padding(.horizontal, 12)
                .animation(.easeInOut(duration: 0.2), value: vm.loadState)
        }
        // 首次显示拉取一次：tab 切换/view 重显时由 hasLoadedOnce 短路，不重复拉
        .task {
            await vm.loadIfNeeded()
        }
        // 下拉刷新：强制重拉（用户主动触发）。系统下拉转圈样式保留默认。
        .refreshable {
            await vm.refresh()
        }
        // Profile 主页设计稿无系统标题栏；FollowList/Settings/LevelDetail 子页内部自行配置 toolbar
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $previewContext) { ctx in
            MediaPreviewView(item: ctx.asset, isVideo: ctx.isVideo) {
                previewContext = nil
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 状态横幅：仅 error 时出现（loading 由 `.refreshable` 系统下拉指示器承担，不叠 banner）。
    @ViewBuilder
    private var statusBanner: some View {
        switch vm.loadState {
        case .idle, .loaded, .loading:
            EmptyView()
        case .error(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(msg)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Text(L10n.profileRetry)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.2), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.7, green: 0.15, blue: 0.2).opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
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
                    items: vm.photos,
                    isVideoGrid: false,
                    onTap: { asset in previewContext = MediaPreviewContext(asset: asset, isVideo: false) }
                )
                ProfileMediaGrid(
                    title: String(format: L10n.profileVideosFormat, vm.videos.count, vm.videosTotal),
                    items: vm.videos,
                    isVideoGrid: true,
                    onTap: { asset in previewContext = MediaPreviewContext(asset: asset, isVideo: true) }
                )
            }
        case .gifts:
            ProfileGiftsTabView(vm: vm)
        case .moment:
            MomentTabView()
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
    ProfileView(path: .constant(NavigationPath()))
}

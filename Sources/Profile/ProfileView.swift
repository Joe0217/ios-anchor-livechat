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
///
/// 图片/视频预览走公共组件 [`MediaGalleryView`](../Core/MediaGallery/MediaGalleryView.swift)（20MB LRU + 横滑翻页 + 下拉关闭）。
/// Photos 与 Videos 分开成两个 URL 列表——用户从 photos section 打开预览时只滑图片，videos section 打开时只滑视频，
/// 保留分区语义。

/// Profile 子页路由枚举。NavigationLink(value:) + navigationDestination(for:) 解耦目标类型。
/// FollowSegment 已是另一个独立 NavigationDestination；本 enum 容纳剩余子页路由。
enum ProfileRoute: Hashable {
    case settings
    case deleteAccount
    case levelDetail
    case dataStatistics
    case blocklist
    case editProfile
    case anchorPolicy
    case language
    case feedback
    case userAgreement
    case privacyPolicy
}

struct ProfileView: View {
    @StateObject private var vm = ProfileViewModel()
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @State private var galleryContext: MediaGalleryContext?
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
                ProfileHeaderView(
                    vm: vm,
                    showsRelationships: permission.canRelationshipViewing,
                    showsCompletionHint: permission.canProfileSocial
                )

                ProfileBioView(bio: vm.bio)

                if showsAlbumContentWithoutTab {
                    albumContent
                } else if !visibleTabs.isEmpty {
                    ProfileTabBar(selected: $vm.selectedTab, tabs: visibleTabs)
                        .padding(.top, 4)

                    contentForSelectedTab
                }
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
        .onChange(of: permission.canVirtualItems) { allowed in
            if !allowed, vm.selectedTab == .gifts {
                vm.selectedTab = .album
            }
        }
        .onChange(of: permission.canProfileSocial) { allowed in
            if !allowed, vm.selectedTab == .moment {
                vm.selectedTab = .album
            }
        }
        .onChange(of: permission.canProfileAlbum) { allowed in
            if !allowed {
                galleryContext = nil
            }
        }
        // Profile 主页设计稿无系统标题栏；FollowList/Settings/LevelDetail 子页内部自行配置 toolbar
        .toolbar(.hidden, for: .navigationBar)
        // iOS 16 已知：`.toolbar(.hidden, for: .navigationBar)` 会截断外层 `.safeAreaInset(edge: .bottom)`
        // 的传播（MainTabView 挂的 tabBarHostContainer 52pt inset 到不了这里）→ ScrollView 内容延伸到
        // system safe area 顶端 → 底部内容被 tabbar 覆盖。此处补一层本地 safeAreaInset 兜底。
        // 未来 root tab view 若隐藏 nav bar，同款套路补一层。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: Theme.Metric.tabBarHeight)
        }
        .fullScreenCover(item: $galleryContext) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
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
            CDNAssetImage("profileTopBg")
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
            if permission.canProfileAlbum {
                albumContent
            }
        case .gifts:
            if permission.canVirtualItems {
                ProfileGiftsTabView(vm: vm)
            } else {
                EmptyView()
            }
        case .moment:
            if permission.canProfileSocial {
                // onMediaPreview 上传 galleryContext → 复用本 view 顶层 fullScreenCover 的公共 MediaGalleryView
                // 见 [swiftui-fullscreencover-hoist.md](../../.claude/rules/swiftui-fullscreencover-hoist.md)：modal 挂唯一容器层
                MomentTabView(onMediaPreview: { galleryContext = $0 })
            }
        }
    }

    private var visibleTabs: [ProfileTab] {
        var tabs: [ProfileTab] = []
        // 107 资料页仅保留基础资料和关系数据，不展示 Album 内容入口。
        if permission.canProfileAlbum, permission.canProfileSocial { tabs.append(.album) }
        if permission.canProfileSocial, permission.canVirtualItems { tabs.append(.gifts) }
        if permission.canProfileSocial { tabs.append(.moment) }
        return tabs
    }

    /// 107 不展示 Album tab，但资料页仍直接展示照片。
    private var showsAlbumContentWithoutTab: Bool {
        permission.canProfileAlbum && !permission.canProfileSocial
    }

    private var isPartyOnlyMode: Bool {
        let effectiveUserType = permission.effectiveUserTypeSnapshot
            ?? UserTypeExperience.effectiveUserType(isAuthenticated: SessionStore.shared.isLoggedIn)
        return UserTypeExperience.isPartyOnly(effectiveUserType)
    }

    private var albumContent: some View {
        VStack(spacing: Theme.Metric.profileGridSectionGap) {
            ProfileMediaGrid(
                title: String(format: L10n.profilePhotosFormat, albumPhotos.count, albumPhotos.count),
                items: albumPhotos,
                isVideoGrid: false,
                onTap: { asset in openGallery(with: albumPhotos, target: asset) }
            )
            if !isPartyOnlyMode {
                ProfileMediaGrid(
                    title: String(format: L10n.profileVideosFormat, albumVideos.count, albumVideos.count),
                    items: albumVideos,
                    isVideoGrid: true,
                    onTap: { asset in openGallery(with: albumVideos, target: asset) }
                )
            }
        }
    }

    /// 107 不具备资料媒体编辑能力，但 Profile 需展示已通过和审核中的照片。
    /// 被拒绝和审核状态未知的内容继续按 fail-closed 隐藏。
    private var albumPhotos: [MediaAsset] {
        permission.canProfileSocial ? vm.photos : vm.photos.filter(Self.isReviewVisible)
    }

    private var albumVideos: [MediaAsset] {
        permission.canProfileSocial ? vm.videos : vm.videos.filter(Self.isReviewVisible)
    }

    private static func isReviewVisible(_ asset: MediaAsset) -> Bool {
        asset.vaild == 1 || asset.vaild == 2
    }

    private var emptyPlaceholder: some View {
        EmptyStateView(style: .compact, textColor: Theme.Palette.profileTabInactive, textFont: Theme.Typography.profileDesc)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
    }

    /// 打开图库预览：取当前 section 全量 URL 列表 + 点击项 index。
    /// 普通账号的 vaild=3 被拒项由 `ProfileMediaGrid` 禁用；107 在进入网格前只保留 vaild=1/2。
    private func openGallery(with items: [MediaAsset], target: MediaAsset) {
        let urls = items.compactMap { $0.url }
        guard !urls.isEmpty else { return }
        // 用 assetId 匹配起始 index；缺 id 时 fallback URL 相等；仍缺时从头开始
        let idx: Int = {
            if let tid = target.assetId,
               let i = items.firstIndex(where: { $0.assetId == tid }) {
                return items[..<i].compactMap { $0.url }.count
            }
            if let tUrl = target.url,
               let i = urls.firstIndex(of: tUrl) {
                return i
            }
            return 0
        }()
        galleryContext = MediaGalleryContext(urls: urls, startIndex: idx)
    }
}

#Preview {
    ProfileView(path: .constant(NavigationPath()))
}

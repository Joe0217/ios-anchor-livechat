import SwiftUI

/// Circle 朋友圈主容器（对齐 H5 `circle/{official,moment,me}.vue` 三 sub-tab 入口）。
///
/// **三 store 设计**：official / moment / me 各持独立 `MomentFeedStore`，分别拉 `officalType=1/2/3`。
/// store 都挂 `@StateObject` 在本容器层——避免 sub tab 切换时重建（违反 §5.7/§5.8 状态保留验收）。
///
/// **Lazy load 策略**（对齐 [MainTabView keep-alive 架构](../MainTabView.swift)）：
/// - 不在 view tree mount 时触发 enterMoment（启动即预热反模式）
/// - 双条件触发：`isActive`（outer tab == .circle）+ `isHomeTabActive`（home tab 被选中）+ `loadState == .idle`
/// - 当前 sub 对应的 store 才触发，旧 sub 的 inflight cancel
struct CircleView: View {
    /// LiveTabView 注入：当前 outer tab 是否是 .circle。
    /// 与 `\.isHomeTabActive` 组合判定"CircleView 是否真的对用户可见"。
    let isActive: Bool

    @Environment(\.isHomeTabActive) private var isHomeTabActive

    @StateObject private var circleStore = CircleStore()
    // R3：3 个 MomentFeedStore 用 @State 而非 @StateObject 持有——
    // 关键差别：@State 保证 class 引用跨 body eval 稳定但**不订阅** ObservableObject.objectWillChange，
    // @StateObject 会订阅，任一 store publish 都触发 CircleView.body 重算 → keep-alive 架构下污染放大。
    // MomentView 内部仍用 @ObservedObject 订阅自身对应 store，子 view 独立响应。
    // 见 [.claude/rules/swiftui-keepalive-publisher-isolation.md](../../../.claude/rules/swiftui-keepalive-publisher-isolation.md)
    @State private var officialStore = MomentFeedStore(source: .official)
    @State private var momentStore = MomentFeedStore(source: .moment)
    @State private var meStore: MomentFeedStore

    /// 发布朋友圈 sheet 开关（Step 1b）
    @State private var showPublishSheet: Bool = false

    /// 图片/视频大图预览挂载点（统一挂在容器层，避免 TabView 内每 tag 挂 cover 竞态）。
    /// 见 [MediaGalleryContext](../../Core/MediaGallery/MediaGalleryView.swift) 类型定义处的详细说明。
    @State private var mediaPreview: MediaGalleryContext?
    /// 删除动态二次确认 pending 项（`me` 入口专用）
    @State private var pendingDeletePost: MomentPost?

    init(isActive: Bool) {
        self.isActive = isActive
        // me 子 tab 需要 userId 走 `keyword` 参数；无登录态时 0 兜底（拉不到数据但不崩）
        let userId = SessionStore.shared.user?.userId ?? 0
        _meStore = State(wrappedValue: MomentFeedStore(source: .me(userId: userId)))
    }

    var body: some View {
        VStack(spacing: 0) {
            CircleSubTabBar(selected: $circleStore.currentSub)

            TabView(selection: $circleStore.currentSub) {
                // 三入口视觉差异（对齐 H5 `circle/{official,moment,me}.vue`）：
                // - official: 无删除、无评论计数（showContent=false 只读模式）
                // - moment:   无删除、有评论计数（大众广场）
                // - me:       有删除、有评论计数（自己的朋友圈，删除业务待发布功能里程碑接入）
                MomentView(store: officialStore,
                           showDelete: false,
                           showComment: false,
                           onMediaPreview: { mediaPreview = $0 })
                    .tag(CircleSubTab.official)
                MomentView(store: momentStore,
                           showDelete: false,
                           showComment: false,  // 对齐 H5 moment.vue 默认 :show-content=false（组件 defineProps default）
                           onMediaPreview: { mediaPreview = $0 })
                    .tag(CircleSubTab.moment)
                MomentView(store: meStore,
                           showDelete: true,
                           showComment: true,
                           onDeleteTap: { post in
                               // 触发二次确认（iOS HIG：破坏性动作应加确认；H5 无但 iOS trash icon 只有 14pt 更易误触）
                               pendingDeletePost = post
                           },
                           onMediaPreview: { mediaPreview = $0 })
                    .tag(CircleSubTab.me)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        // 右下角浮动发布按钮（Step 1b）
        // 避开 MainTabView 自定义 TabBar（Theme.Metric.tabBarHeight=52）+ 16pt 视觉间距 = 68
        .overlay(alignment: .bottomTrailing) {
            CircleFloatingPostButton {
                showPublishSheet = true
            }
            .padding(.trailing, 16)
            .padding(.bottom, Theme.Metric.tabBarHeight + 16)
        }
        // 发布 sheet：默认 runtime 工厂注入 PostPublishService / OssCredentialService / OssUploadService
        .sheet(isPresented: $showPublishSheet) {
            PostPublishView(viewModel: PostPublishViewModel.makeRuntime())
                .giftPanelSheetBackground()
        }
        // 图片/视频大图预览（统一挂在容器层——见 mediaPreview 定义处说明）
        .fullScreenCover(item: $mediaPreview) { ctx in
            MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
        }
        // 删除动态二次确认（对齐 UserProfileBlockConfirmDialog 模式）
        .confirmationDialog(
            L10n.momentDeleteConfirmTitle,
            isPresented: Binding(
                get: { pendingDeletePost != nil },
                set: { newVal in if !newVal { pendingDeletePost = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletePost
        ) { post in
            Button(L10n.momentDeleteConfirmAction, role: .destructive) {
                if let id = post.postId { meStore.deletePost(postId: id) }
                pendingDeletePost = nil
            }
            Button(L10n.momentDeleteConfirmCancel, role: .cancel) {
                pendingDeletePost = nil
            }
        }
        // Lazy load 三入口：可见性 / outer tab 切换 / sub tab 切换 任一变化都重新检查
        .onChange(of: circleStore.currentSub) { newSub in
            triggerCurrentSubLoadIfNeeded()
            cancelOtherSubsInflight(except: newSub)
        }
        // 离开朋友圈页面清空预览媒体缓存——用户诉求：不跨"朋友圈页面"。
        // keep-alive 架构下 onDisappear 不总触发，改用 isActive/isHomeTabActive true→false 语义清空。
        .onChange(of: isHomeTabActive) { active in
            triggerCurrentSubLoadIfNeeded()
            if !active { MediaGalleryCache.shared.clear() }
        }
        .onChange(of: isActive) { active in
            triggerCurrentSubLoadIfNeeded()
            if !active { MediaGalleryCache.shared.clear() }
        }
        // **不加 .onDisappear { clear() }**：SwiftUI fullScreenCover 打开时会让底层 CircleView 走 onDisappear
        // (iOS 14+ modal 覆盖被视作 hierarchy 变化)，会导致每次点视频预览都清空 pool，破坏缓存意图。
        // isActive/isHomeTabActive → false 已覆盖"离开朋友圈"的所有真实场景（切 outer tab / 切 Home tab）。
        // 兜底：TabView(.page) 若 lazy 创建 tag view，CircleView 首次 mount 时
        // isActive 初始就是 true，`.onChange(of: isActive)` 没有 false→true 变化历史不触发。
        // .task 在 view mount 时跑一次，触发首次 lazy load（enterMoment 是 idempotent，安全）。
        .task {
            triggerCurrentSubLoadIfNeeded()
        }
    }

    /// 当前 sub 对应的 store 是 .idle 且 CircleView 可见时，触发 enterMoment。
    /// enterMoment 自身 idempotent，重复调用安全。
    private func triggerCurrentSubLoadIfNeeded() {
        guard isHomeTabActive, isActive else { return }
        storeFor(circleStore.currentSub).enterMoment()
    }

    /// 切走的 sub 取消 inflight，避免不可见 store 浪费网络。
    private func cancelOtherSubsInflight(except current: CircleSubTab) {
        for sub in CircleSubTab.allCases where sub != current {
            storeFor(sub).cancelInflight()
        }
    }

    private func storeFor(_ sub: CircleSubTab) -> MomentFeedStore {
        switch sub {
        case .official: return officialStore
        case .moment:   return momentStore
        case .me:       return meStore
        }
    }
}

#if DEBUG
struct CircleView_Previews: PreviewProvider {
    static var previews: some View {
        CircleView(isActive: true)
            .background(Color.black)
            .preferredColorScheme(.dark)
            .previewDisplayName("Circle 容器（默认 Official）")
    }
}
#endif

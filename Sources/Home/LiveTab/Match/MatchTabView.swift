import Combine
import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MatchTabView")

/// L 里程碑：Match tab 页面内容。
///
/// 组合：跑马灯（顶部）+ 主视觉合成图（中部）+ 用户列表（底部）+ 背景切图。
/// 详见 `docs/plan/L-spec-视频匹配Match-*.md` §4.1。
///
/// **加载策略**：仅在 Home 与 Match 子 tab 均实际可见且具备通话能力时触发 `loadIfNeeded()`。
/// **交互**：点击用户卡片 → sheet 弹出用户详情（MVP 阶段用 fullScreenCover 前的 sheet 简化）。
struct MatchTabView: View {
    /// Home 的 TabView 会预创建所有子页；由父层传入真实可见性，避免隐藏页预热匹配池。
    var isActive: Bool = true
    @StateObject private var vm = MatchTabViewModel()

    // 摄像头会话与匹配预览浮窗 **已提到 MainTabView 层**（跨 tab 全局展示），
    // 本 View 只负责 tab 内容（跑马灯 / 主图 / 用户列表）

    var body: some View {
        VStack(spacing: 0) {
            // 顶部跑马灯（H5 主播端行为：一直显示；空 callList → demo fallback 由组件内部处理）
            MatchMarqueeView(records: vm.callList)
                .padding(.top, 8)

            // 主视觉图
            MatchHeroView()
                .padding(.top, 12)

            // 小头像 row（用户反馈 #2：头像放在文案上面）
            MatchUserListView(
                users: vm.userList,
                onTapUser: { user in vm.presentUserCard(user) }
            )
            .padding(.top, 12)

            // 描述文字（在头像下方）
            Text(L10n.matchSubtitleDescription)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Theme.Palette.matchSubtitle)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Metric.matchSubtitleTopGap)
                .padding(.horizontal, 32)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 背景切图作为背景层（用 `.background` modifier 而非 ZStack child，
        // 避免 scaledToFill + 无 height 约束时挤压 VStack layout）
        .background(
            CDNAssetImage("matchBackgroundHigh")
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        )
        .background(Theme.Palette.matchPageBackground)
        .clipped()
        // 摄像头浮窗/attach 已在 MainTabView 层做全局管理
        .task(id: isActive) {
            guard isActive else { return }
            await vm.loadIfNeeded()
        }
        .sheet(item: $vm.presentedUser) { user in
            MatchUserCardSheet(user: user)
                .sheetTopInset()
                .giftPanelSheetBackground()
                .presentationDetents([.medium])
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - ViewModel

@MainActor
final class MatchTabViewModel: ObservableObject {
    @Published private(set) var callList: [MatchCallRecord] = []
    @Published private(set) var userList: [MatchUserItem] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published var presentedUser: MatchUserItem?

    private let service: MatchServiceProtocol
    private var hasLoaded = false

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    init(service: MatchServiceProtocol = MatchService.shared) {
        self.service = service
    }

    /// 首次进入触发（onAppear）；已加载则跳过。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        loadState = .loading
        do {
            let pool = try await service.loadMatchPoolData()
            guard !Task.isCancelled else {
                hasLoaded = false
                loadState = .idle
                return
            }
            callList = pool.callList
            userList = pool.userList
            loadState = .loaded
            logger.info("MatchTab loaded: callList=\(pool.callList.count) userList=\(pool.userList.count)")
        } catch is CancellationError {
            // `task(id:)` 在切走 Home/Match 时会取消；保留 idle 让下次真正进入时可重试。
            hasLoaded = false
            loadState = .idle
        } catch {
            loadState = .error(String(describing: error))
            logger.error("MatchTab load failed: \(String(describing: error))")
        }
    }

    func presentUserCard(_ user: MatchUserItem) {
        presentedUser = user
    }
}

// MARK: - Preview

#Preview("loaded") {
    let vm = MatchTabViewModel(service: PreviewMatchService())
    return MatchTabView_PreviewWrapper(vm: vm)
}

#Preview("empty") {
    let vm = MatchTabViewModel(service: PreviewMatchService(users: [], calls: []))
    return MatchTabView_PreviewWrapper(vm: vm)
}

private struct MatchTabView_PreviewWrapper: View {
    @StateObject var vm: MatchTabViewModel

    var body: some View {
        VStack(spacing: 0) {
            MatchMarqueeView(records: vm.callList)
                .padding(.top, 8)
            MatchHeroView()
                .padding(.top, 12)
            MatchUserListView(users: vm.userList, onTapUser: { _ in })
                .padding(.top, 12)
            Text(L10n.matchSubtitleDescription)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(Theme.Palette.matchSubtitle)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Metric.matchSubtitleTopGap)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            CDNAssetImage("matchBackgroundHigh")
                .resizable()
                .scaledToFill()
        )
        .background(Theme.Palette.matchPageBackground)
        .clipped()
        .task { await vm.load() }
        .preferredColorScheme(.dark)
    }
}

private final class PreviewMatchService: MatchServiceProtocol {
    let users: [MatchUserItem]
    let calls: [MatchCallRecord]

    init(users: [MatchUserItem]? = nil, calls: [MatchCallRecord]? = nil) {
        self.users = users ?? (1...6).map { i in
            MatchUserItem.previewFixture(userId: "\(i)", nickname: "U\(i)", age: 20 + i)
        }
        self.calls = calls ?? [
            MatchCallRecord(callerIcon: "", callerNickname: "James",
                            receiverIcon: "", receiverNickname: "Emma"),
            MatchCallRecord(callerIcon: "", callerNickname: "Alice",
                            receiverIcon: "", receiverNickname: "Bob"),
        ]
    }

    func isMatchOpen() async throws -> MatchCanOpenResult { .allowed }
    func toggleMatch(status: Int, faceCheckStatus: Int?) async throws -> Bool { true }
    func reportNoFace(imageURL: String) async throws {}
    func loadMatchPoolData() async throws -> MatchPoolData {
        MatchPoolData(callList: calls, userList: users)
    }
    func loadMatchList(pageNum: Int, pageSize: Int) async throws -> [MatchUserItem] { users }
}

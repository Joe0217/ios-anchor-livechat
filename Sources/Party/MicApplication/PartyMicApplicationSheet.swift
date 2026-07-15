import SwiftUI

/// 派对房「排麦申请列表」sheet（房主/房管视角）— 对齐 H5
/// `livechat-h5/src/components/party/components/seat-apply-popup.vue`。
///
/// spec §2 房主端 + §4 A3/R6/R7/R11 + list-refresh-preserve-items rule：
/// - `.task` 首次拉取（reason=.initial）
/// - `.refreshable` 下拉刷新（reason=.refresh，保留 items 视觉；await 到任务完成，spinner 不闪）
/// - `.refreshing([items])` 状态与 `.loaded` 视觉一致，仅 SwiftUI 自带顶部 spinner 表达"刷新中"
struct PartyMicApplicationSheet: View {
    @ObservedObject var store: PartyStore
    /// spec §2 房主端 A4：Owner tap switch toggle → 上层弹 SwitchConfirmSheet 走首次协议 or 直接调 API
    /// 观众视角 hidden。closure 由 PartyRoomView 层接 activeRoomTool = .micApplicationSwitchConfirm
    var onTapSwitchToggle: (() -> Void)? = nil

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                contentArea
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await store.loadMicApplications(reason: .initial)
        }
    }

    // MARK: - Header (title + count badge + owner switch toggle)

    private var header: some View {
        ZStack {
            VStack(spacing: 8) {
                Text(L10n.Party.micApplicationSheetTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(height: 52)
                // spec §3 顶部计数 —— queueSeatNum 独立于 items 数（服务端权威计数）
                Text("\(store.queueSeatNum)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                    .padding(.bottom, 4)
            }
            // 房主专用：右上角 switch toggle 按钮触发 first-time 协议确认 or 直接切
            if store.selfRole == .owner, let tap = onTapSwitchToggle {
                HStack {
                    Spacer()
                    Button(action: tap) {
                        Image(systemName: store.micApplicationSwitchOn ? "bell.fill" : "bell.slash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.white.opacity(0.15)))
                            .padding(.trailing, 16)
                            .padding(.top, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.micApplicationSwitchOn
                        ? L10n.Party.micApplicationSwitchOffTitle
                        : L10n.Party.micApplicationSwitchOnTitle)
                }
            }
        }
    }

    // MARK: - Content area (state-driven)

    @ViewBuilder
    private var contentArea: some View {
        switch store.micApplicationsState {
        case .idle, .loading:
            loadingView
        case .loaded(let items), .refreshing(let items):
            // list-refresh-preserve-items rule：.refreshing 保留 items 视觉，
            // SwiftUI .refreshable 自身管顶部 spinner
            listView(items: items)
        case .empty:
            emptyView
        case .error(let msg):
            errorView(message: msg)
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView().tint(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.5))
            Text(L10n.Party.micApplicationEmptyState)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.partyGreeting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                Task { await store.loadMicApplications(reason: .initial) }
            } label: {
                Text(L10n.Party.retry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listView(items: [PartyMicApplication]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items) { item in
                    row(item: item)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            // list-refresh-preserve-items rule B：closure 必须 await 到任务完成，spinner 才保持
            await store.refreshMicApplications()
        }
    }

    // MARK: - Row

    private func row(item: PartyMicApplication) -> some View {
        HStack(spacing: 8) {
            avatar(url: item.avatar)
            middleInfo(item: item)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions(item: item)
        }
        .padding(.vertical, 6)
    }

    private func avatar(url: String?) -> some View {
        // 小头像走 avatarSmall（w_180）+ fill 保命中率（cdn-image-tier-consolidation preference）
        CachedAsyncImage(
            url: url.flatMap(URL.init(string:)),
            contentMode: .fill,
            cdn: (.avatarSmall, .fill)
        ) {
            Circle().fill(Color.white.opacity(0.1))
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func middleInfo(item: PartyMicApplication) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.nickname)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            HStack(spacing: 4) {
                if item.gender != nil || item.age != nil {
                    genderAgeChip(gender: item.gender, age: item.age)
                }
                if let vip = item.vip, vip > 0 {
                    vipBadge
                }
                if let lv = item.levelName, !lv.isEmpty {
                    levelBadge(levelName: lv)
                }
            }
        }
    }

    private func genderAgeChip(gender: Int?, age: Int?) -> some View {
        // gender 1 = 男（蓝），2 = 女（粉）；无 gender 有 age 走灰底
        let bg: Color = {
            switch gender {
            case 1: return Color(red: 0.13, green: 0.37, blue: 1.0)
            case 2: return Color(red: 1.0, green: 0.10, blue: 0.65)
            default: return Color(white: 0.58)
            }
        }()
        return HStack(spacing: 2) {
            if let g = gender, g == 1 || g == 2 {
                Image(systemName: g == 1 ? "person.fill" : "person.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white)
            }
            if let a = age {
                Text("\(a)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Capsule().fill(bg))
    }

    private var vipBadge: some View {
        Text("VIP")
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.75, blue: 0.10),
                                 Color(red: 0.98, green: 0.42, blue: 0.10)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
    }

    private func levelBadge(levelName: String) -> some View {
        Text("Lv.\(levelName)")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(Capsule().fill(Color(red: 0.31, green: 0.24, blue: 0.66)))
    }

    // MARK: - Actions

    private func actions(item: PartyMicApplication) -> some View {
        HStack(spacing: 8) {
            // Reject（secondary，白描边空心）
            Button {
                Task { await store.refuseMicApplication(userId: item.userId) }
            } label: {
                Text(L10n.Party.micApplicationReject)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            // Approve（primary，紫底填充；spec §2 seatIndex=nil 让 store 挑首空位排除 pending 集合）
            Button {
                Task {
                    await store.agreeMicApplication(userId: item.userId, seatIndex: nil)
                }
            } label: {
                Text(L10n.Party.micApplicationApprove)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        Capsule().fill(Color(red: 0.21, green: 0.14, blue: 0.67))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

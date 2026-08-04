import SwiftUI

/// Phase C —— 任务中心页主容器。对齐 H5 [`views/task/index.vue`](../../../../Desktop/HN/anchor-livechat-h5/src/views/task/index.vue) 主结构。
///
/// **布局**:
/// - RankHeader(myIncome / myIntegral)
/// - Tabs(Daily / Weekly)
/// - CountdownBar(重置倒计时 + Weekly 附 Total Points)
/// - 主体分派:idle/loading → 骨架 3 卡;error → 全屏错误 + Retry;loaded → module 列表 + Weekly 独有区块
/// - 领奖弹窗(overlay,pendingReward 触发)
///
/// **Weekly 独有**:module 列表下方追加 tycoonTask 折叠块 + integralTask 折叠块。
///
/// **rank tap**:由 `rankProgressAction` 注入首页榜单路由。
struct TaskCenterView: View {
    @StateObject private var store = TaskCenterStore()
    @State private var legacyMatchTipPresented = false

    @Environment(\.rankProgressAction) private var rankProgressAction

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                // 顶部粉紫渐变背景 —— `.resizable()` + 仅 height 拉伸铺满宽度,不用 aspectRatio(.fill)
                // 避免图片按 aspect ratio 撑到超出屏宽 → ZStack 宽度被拉大 → VStack 内容溢出
                CDNAssetImage("taskTopBg")
                    .resizable()
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.taskRankProgress)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 10)

                    TaskRankHeader(
                        rank: store.rankInfo,
                        onIncomeTap: { rankProgressAction?(.income) },
                        onIntegralTap: { rankProgressAction?(.integral) }
                    )

                    Text(L10n.taskProgress)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.top, 14)

                    TaskTabBar(active: store.activeCycle) { cycle in
                        store.switchCycle(cycle)
                    }
                    .padding(.top, 2)

                    TaskCountdownBar(
                        cycle: store.activeCycle,
                        weeklyServerRemainSeconds: store.weeklyResetRemainSeconds,
                        weeklyTotalPoints: store.pointsInfo?.myIntegral,
                        onWeeklyReset: store.refreshWeeklyAfterReset
                    )
                    .padding(.top, 4)

                    mainContent
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollIndicators(.hidden)
        .background(Color(hex: 0x0B0010).ignoresSafeArea())
        .refreshable { await store.refresh() }
        .navigationTitle(L10n.taskCenterNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        // nav bar 用深紫背景匹配顶部 taskTopBg,不做 hidden(避免系统蓝色 back 露出)
        .toolbarBackground(Color(hex: 0x39147A), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .overlay {
            if let reward = store.pendingReward {
                TaskClaimRewardPopup(reward: reward) {
                    store.pendingReward = nil
                }
                .transition(.opacity)
                .zIndex(1000)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: store.pendingReward != nil)
        .alert(L10n.taskLegacyMatchTipTitle, isPresented: $legacyMatchTipPresented) {
            Button(L10n.commonConfirm, role: .cancel) {}
        } message: {
            Text(L10n.taskLegacyMatchTipMessage)
        }
        .task { store.onAppear() }
    }

    // MARK: - 主体分派

    @ViewBuilder
    private var mainContent: some View {
        if store.activeCycle == .daily, store.shouldUseLegacyDailyTasks {
            legacyDailyContent
        } else {
            currentCycleContent
        }
    }

    @ViewBuilder
    private var currentCycleContent: some View {
        switch store.state {
        case .idle, .loading(previous: nil), .error(_, previous: nil):
            skeletonPlaceholder
        case .loading(let groups?), .loaded(let groups), .error(_, let groups?):
            groupsList(groups)
        }
    }

    private var legacyDailyContent: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            legacyTaskSection(
                title: L10n.taskLegacyLimitedTime,
                tasks: store.legacyDailyTasks?.limitedTimeTasks ?? []
            )
            legacyTaskSection(
                title: L10n.taskLegacyAllDay,
                tasks: store.legacyDailyTasks?.allDayTasks ?? []
            )
        }
    }

    private func legacyTaskSection(title: String, tasks: [LegacyTaskVO]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 12)
            Divider().overlay(Color.white.opacity(0.08))
                .padding(.bottom, 12)

            if tasks.isEmpty {
                Text(L10n.taskModuleNoTasks)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                    legacyTaskRow(task)
                    if index < tasks.count - 1 {
                        Divider().overlay(Color.white.opacity(0.08))
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x251A3A))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func legacyTaskRow(_ task: LegacyTaskVO) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(task.taskName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if task.taskType == "matchNum" {
                        Button {
                            legacyMatchTipPresented = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) {
                    Text("(\(task.curScore)/\(task.targetScore))")
                    if let effectiveTime = task.effectiveTime, !effectiveTime.isEmpty {
                        CDNAssetImage("pinkClock")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 12, height: 12)
                        Text(effectiveTime)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 4) {
                    CDNAssetImage(task.rewardType == 2 ? "homeRankIntegral" : "diamondYellow")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                    Text("+\(task.rewardValue)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFFE600))
                }
            }
            Spacer(minLength: 4)
            Button {
                Task { await store.claimLegacyTask(taskId: task.taskId) }
            } label: {
                if store.isClaimingLegacyTask(taskId: task.taskId) {
                    ProgressView().tint(.white)
                } else {
                    Text(task.isClaimed ? L10n.taskTierClaimed : L10n.taskTierClaim)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 28)
            .background(task.isClaimed ? Color(hex: 0x140000) : Color(hex: 0x8515FF))
            .clipShape(Capsule())
            .buttonStyle(.plain)
            .disabled(!task.isClaimable || store.isClaimingLegacyTask(taskId: task.taskId))
        }
    }

    private func groupsList(_ groups: [TaskModuleGroupVO]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                TaskModuleGroup(
                    group: group,
                    isCollapsed: store.collapsed.contains(group.moduleCode),
                    store: store
                )
            }

            // Weekly 独有:tycoon + integral 折叠块
            if store.activeCycle == .weekly {
                if !store.tycoonTasks.isEmpty {
                    TaskCollapsibleSection(
                        title: L10n.taskActiveTycoonTask,
                        iconAsset: "taskModuleIconTycoon",
                        isExpanded: Binding(
                            get: { store.tycoonExpanded },
                            set: { store.setWeeklySection(.tycoon, isExpanded: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(store.tycoonTasks) { t in
                                TaskTycoonCard(task: t)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let pInfo = store.pointsInfo, !pInfo.taskVos.isEmpty {
                    TaskCollapsibleSection(
                        title: L10n.taskIntegralTask,
                        iconAsset: "taskModuleIconPoints",
                        isExpanded: Binding(
                            get: { store.pointsExpanded },
                            set: { store.setWeeklySection(.points, isExpanded: $0) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(pInfo.taskVos) { pt in
                                integralTaskRow(pt)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            // 全屏 loading 兜底(有 previous 时用 spinner overlay,此处保留占位)
            if store.state.isLoading {
                HStack {
                    Spacer()
                    ProgressView().tint(.white)
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func integralTaskRow(_ pt: WeeklyPointsTaskVO) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xFFCC00))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(pt.taskName ?? "-")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let desc = pt.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(2)
                }
                Text("\(pt.curScore) / \(pt.targetScore)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x191423))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 骨架屏 / 错误态

    private var skeletonPlaceholder: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.cardFill)
                    .frame(height: 120)
                    .overlay(
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)).frame(height: 14).frame(maxWidth: 100)
                            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)).frame(height: 10).frame(maxWidth: .infinity)
                            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)).frame(height: 6)
                        }
                        .padding(12)
                    )
            }
        }
        .padding(.top, 4)
    }

}

// MARK: - Environment: rank card tap action(H5 独立榜单页;iOS 首版 Coming Soon)

enum TaskRankTarget {
    case income, integral
}

private struct RankProgressActionKey: EnvironmentKey {
    static let defaultValue: ((TaskRankTarget) -> Void)? = nil
}

extension EnvironmentValues {
    var rankProgressAction: ((TaskRankTarget) -> Void)? {
        get { self[RankProgressActionKey.self] }
        set { self[RankProgressActionKey.self] = newValue }
    }
}

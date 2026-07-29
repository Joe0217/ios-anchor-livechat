import SwiftUI

/// 任务模块分组卡。对齐设计稿:
/// - Title bar:左侧**紫方块图标**(切图,按 moduleCode 派生)+ 模块名(白)+ 右侧黄圆展开箭头
/// - 分割线(白 10% 透明)
/// - Body:collapsed=true 时隐藏;expanded 显示 tasks[];**多档 tier(≥2)** 走 [TaskWeeklyTierBar];其余走 [TaskTierRow]
struct TaskModuleGroup: View {
    let group: TaskModuleGroupVO
    let isCollapsed: Bool
    let store: TaskCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.toggleCollapse(group.moduleCode, moduleName: group.moduleName)
                }
            } label: {
                headerRow
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                Divider().background(Color.white.opacity(0.08))
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: rowMode == .simple ? 14 : 10) {
                    if group.tasks.isEmpty {
                        // 空态(对齐 H5 ModuleGroup 内部 task.no_tasks)
                        Text(L10n.taskModuleNoTasks)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(group.tasks) { task in
                            if task.tiers.count >= 2 {
                                weeklyRevenueRow(task)
                            } else {
                                TaskTierRow(
                                    task: task,
                                    displayMode: rowMode,
                                    isClaimingTier: { store.isClaimingTier(taskId: task.taskId, tier: $0) },
                                    isClaimingAll: store.isClaimingAll(taskId: task.taskId),
                                    onClaim: { tier in Task { await store.claim(taskId: task.taskId, tier: tier) } },
                                    onClaimAll: { Task { await store.claimAll(taskId: task.taskId) } }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(hex: 0x251A3A))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(moduleIconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
            Text(group.moduleName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            if group.derivedHasRedDot {
                Circle().fill(Color(hex: 0xFF3B30)).frame(width: 8, height: 8)
            }
            Spacer()
            // Total Points 模块右上显示总积分数(设计稿 "3000");其他 module 只显箭头
            if isPointsModule, let total = totalPointsValue {
                Text("\(total)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(hex: 0xFFE600))
                    .padding(.trailing, 2)
            }
            Image(systemName: isCollapsed ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color(hex: 0xFFE600))
        }
    }

    /// Total Points 模块判定(根据 moduleCode / moduleName 关键字)
    private var isPointsModule: Bool {
        let n = group.moduleName.lowercased()
        return n.contains("total points") || group.moduleCode.lowercased().contains("points")
    }

    /// Total Points 数字:仅 Weekly + Points 模块显示;数据源 store.pointsInfo.anchorCurScore
    private var totalPointsValue: Int? {
        isPointsModule ? store.pointsInfo?.anchorCurScore : nil
    }

    /// moduleCode → 切图名 映射(未知走 taskModuleIconPoints 兜底)
    private var moduleIconName: String {
        let code = group.moduleCode.lowercased()
        let name = group.moduleName.lowercased()
        if code.contains("live") || name.contains("live stream") { return "taskModuleIconLive" }
        if code.contains("tycoon") || name.contains("tycoon") { return "taskModuleIconTycoon" }
        return "taskModuleIconPoints"
    }

    /// 派生本 module 的任务行显示模式(设计稿约定:
    /// - Points 类模块 → simple 堆叠
    /// - Tycoon 类模块 → progress 进度条(嵌入卡)
    /// - Live stream 类模块 → actionable(Claim/Go 按钮 + 底 bar)
    /// - 其他 → 兜底 actionable)
    private var rowMode: TaskTierRow.DisplayMode {
        let code = group.moduleCode.lowercased()
        let name = group.moduleName.lowercased()
        if code.contains("points") || name.contains("total points") { return .simple }
        if code.contains("tycoon") || name.contains("tycoon") { return .progress }
        return .actionable
    }

    private func weeklyRevenueRow(_ task: TaskItemVO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.taskName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                        if task.derivedHasRedDot {
                            Circle().fill(Color(hex: 0xFF3B30)).frame(width: 7, height: 7)
                        }
                    }
                    if let desc = task.taskDesc, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer()
                if task.derivedHasClaimable {
                    Button {
                        Task { await store.claimAll(taskId: task.taskId) }
                    } label: {
                        Text(L10n.taskTierClaim)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(
                                LinearGradient(colors: [Color(hex: 0xF640DC), Color(hex: 0x8515FF)],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            TaskWeeklyTierBar(
                task: task,
                isClaimingTier: { store.isClaimingTier(taskId: task.taskId, tier: $0) },
                onClaim: { tier in Task { await store.claim(taskId: task.taskId, tier: tier) } }
            )
        }
        .padding(.vertical, 4)
    }
}

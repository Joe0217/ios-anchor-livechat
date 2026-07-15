import SwiftUI

/// 工具区：标题行 + 4 列工具图标网格。对齐 H5 work/index.vue workspaceItems。
/// Invite 图标顶部悬浮"Earn Money"金色渐变角标（H5 style）。
/// Newbie / BigR 由 visibility 接口控制显示（value 参数传入，非 @ObservedObject，避免 vm 死订阅）。
/// Online 开关已改为 WorkView 悬浮层，不再放本区。
struct ToolsSection: View {
    // Newbie / bigR 由 WorkViewModel.showNewbie / showBigR 拉取后传入。
    // 用 value 而非 @ObservedObject vm：只在这两个 Bool 变化时 diff 重算，
    // 不订阅 vm 的其他 @Published（避免 onlineTimeSec / callIncomes 变化时 12+ 图标网格重算 —— 审查报告-202607061550 必修-1）。
    let showNewbie: Bool
    let showBigR: Bool

    /// 由 MainTabView 注入：Match 图标 tap 切到 Home + Match top tab（对齐首页 Match 入口）
    @Environment(\.openHomeMatch) private var openHomeMatch

    /// 工具项（图标资源名 + 标签）。顺序与 H5 workspaceItems 一致（Hi 已移除）。
    /// Newbie 插在 Task 之后（H5 位置）、bigR 插在 Invite 之后。
    private var tools: [(icon: String, label: String)] {
        var arr: [(icon: String, label: String)] = [
            ("toolGoLive", L10n.toolGoLive),
            ("toolMatch", L10n.toolMatch),
            ("toolTask", L10n.toolTask),
        ]
        if showNewbie { arr.append(("toolNewbie", L10n.toolNewbie)) }
        arr.append(contentsOf: [
            ("toolBeauty", L10n.toolBeauty),
            ("toolPoints", L10n.toolPoints),
            ("toolGiftMessage", L10n.toolGiftMessage),
            ("toolProfileUpdate", L10n.toolProfileUpdate),
            ("toolInvite", L10n.toolInvite),
        ])
        if showBigR { arr.append(("toolBigR", L10n.toolBigR)) }
        arr.append(contentsOf: [
            ("toolWorkingGuide", L10n.toolWorkingGuide),
            ("toolBackpack", L10n.toolBackpack),
            ("toolLiveData", L10n.toolLiveData),
            ("toolPartyData", L10n.toolPartyData),
            ("toolMyGuardian", L10n.toolMyGuardian),
        ])
        return arr
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                                count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.workTools)
                .font(Theme.Typography.sectionTitle)
                .foregroundStyle(.white)

            Rectangle()
                .fill(Theme.Palette.divider)
                .frame(height: 1)

            LazyVGrid(columns: columns, alignment: .center, spacing: Theme.Metric.toolRowSpacing) {
                ForEach(tools.indices, id: \.self) { i in
                    let cell = toolCell(icon: tools[i].icon, label: tools[i].label)
                    // Go Live → 开播设置页（B-spec-开播设置页 §1.4；生产入口）
                    if tools[i].icon == "toolGoLive" {
                        // 首次开播 → firstLiveRule 10s 规则页；已开播过 → 直接 LiveSettings
                        // 对齐 H5 c-goLive.vue:64 `router.push(userStore.isFirstLive ? '/liveRule?type=3' : '/liveSetting')`
                        // 用 NavigationLink 静态 value 时，body 未重算会缓存旧 value；改用 tap 时动态求值
                        NavigationLink(
                            value: FirstLiveTracker.isFirstLive
                                ? WorkRoute.firstLiveRule
                                : WorkRoute.liveSettings
                        ) { cell }
                            .buttonStyle(.plain)
                    // Match → 切到 Home + Match top tab（对齐首页 Match 入口，与 CGoMatchButton 同一入口）
                    } else if tools[i].icon == "toolMatch" {
                        Button { openHomeMatch.perform() } label: { cell }
                            .buttonStyle(.plain)
                    // Task → Phase C 占位（B-F 阶段替换真页面）
                    } else if tools[i].icon == "toolTask" {
                        NavigationLink(value: WorkRoute.task) { cell }
                            .buttonStyle(.plain)
                    // Beauty → 美颜设置页（K-spec-美颜设置页 §0.4 Q1；生产入口）
                    } else if tools[i].icon == "toolBeauty" {
                        NavigationLink(value: WorkRoute.beautySettings) { cell }
                            .buttonStyle(.plain)
                    // Points → Phase E 占位
                    } else if tools[i].icon == "toolPoints" {
                        NavigationLink(value: WorkRoute.pointsRank) { cell }
                            .buttonStyle(.plain)
                    // Gift Message → 私密媒体解锁页（H-2-spec-私密媒体解锁；生产入口）
                    } else if tools[i].icon == "toolGiftMessage" {
                        NavigationLink(value: WorkRoute.giftMessage) { cell }
                            .buttonStyle(.plain)
                    // Profile Update → EditProfileView（I 里程碑已实现，本次接线）
                    } else if tools[i].icon == "toolProfileUpdate" {
                        NavigationLink(value: WorkRoute.profileEdit) { cell }
                            .buttonStyle(.plain)
                    // Invite → Phase D 占位
                    } else if tools[i].icon == "toolInvite" {
                        NavigationLink(value: WorkRoute.invite) { cell }
                            .buttonStyle(.plain)
                    // Working Guide (Anchor Guide) → Phase F 占位
                    } else if tools[i].icon == "toolWorkingGuide" {
                        NavigationLink(value: WorkRoute.anchorGuide) { cell }
                            .buttonStyle(.plain)
                    // Live Data → Phase B 占位（下一个开工）
                    } else if tools[i].icon == "toolLiveData" {
                        NavigationLink(value: WorkRoute.liveData) { cell }
                            .buttonStyle(.plain)
                    // Party Data / My Guardian → 占位（H5 蓝本无此入口，Downloads UI 新增；未来落地页替换 ComingSoon）
                    } else if tools[i].icon == "toolPartyData" {
                        NavigationLink(value: WorkRoute.partyData) { cell }
                            .buttonStyle(.plain)
                    } else if tools[i].icon == "toolMyGuardian" {
                        NavigationLink(value: WorkRoute.myGuardian) { cell }
                            .buttonStyle(.plain)
                    // Newbie / bigR → 占位（页面本身留 J 里程碑落地；对齐 H5 visibility=true 时显示入口）
                    } else if tools[i].icon == "toolNewbie" {
                        NavigationLink(value: WorkRoute.newbie) { cell }
                            .buttonStyle(.plain)
                    } else if tools[i].icon == "toolBigR" {
                        NavigationLink(value: WorkRoute.bigR) { cell }
                            .buttonStyle(.plain)
                    } else {
                        // Backpack（Props）：路线图未安排，保持无 handler 静态显示
                        cell
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bigCard, style: .continuous))
    }

    // MARK: - 单个工具
    private func toolCell(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(icon)
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.toolTile, height: Theme.Metric.toolTile)
                .accessibilityHidden(true)
                .overlay(alignment: .top) {
                    if icon == "toolInvite" {
                        earnMoneyTag
                            .offset(y: -6)   // H5 top--6
                    }
                }
            Text(label)
                .font(Theme.Typography.toolLabel)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// H5 style: linear-gradient(90deg,#F8A72E 0%,#FF4343 100%)，7pt 字，圆角 5，46×13
    private var earnMoneyTag: some View {
        Text(L10n.inviteEarnMoney)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(height: 13)
            .background(
                LinearGradient(colors: [Color(red: 248/255, green: 167/255, blue: 46/255),
                                        Color(red: 255/255, green: 67/255, blue: 67/255)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

import SwiftUI

/// 工具区：标题行 + 4 列工具图标网格。对齐 H5 work/index.vue workspaceItems。
/// Invite 图标顶部悬浮"Earn Money"金色渐变角标（H5 style）。
/// Newbie 由 visibility 接口控制显示（value 参数传入，非 @ObservedObject，避免 vm 死订阅）。
/// Online 开关已改为 WorkView 悬浮层，不再放本区。
struct ToolsSection: View {
    // Newbie 由 WorkViewModel.showNewbie 拉取后传入。
    // 用 value 而非 @ObservedObject vm：只在这个 Bool 变化时 diff 重算，
    // 不订阅 vm 的其他 @Published（避免 onlineTimeSec / callIncomes 变化时 12+ 图标网格重算 —— 审查报告-202607061550 必修-1）。
    let showNewbie: Bool
    /// Work 根页的全部 push 都必须写入 MainTabView 持有的 path，确保任何二级页自动隐藏 TabBar。
    @Binding var path: NavigationPath

    /// 由 MainTabView 注入：Match 图标 tap 切到 Home + Match top tab（对齐首页 Match 入口）
    @Environment(\.openHomeMatch) private var openHomeMatch
    /// 与首页 QuickGoLive 共用入口协调：最小化 Party 房时先弹确认并完整退房。
    @Environment(\.quickGoLive) private var quickGoLive
    /// v2 code-review Finding 1：观察 SelfPermissionBridge 让 canCall/canLive/canParty 变化触发 body 重算，
    /// cell 显隐同步更新（原直接读 shared.canX 无订阅，权限翻转后 cell stale）。
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @State private var showBeautyPermissionAlert = false
    @State private var pendingBeautyMode: BeautySettingsView.Mode?

    /// 工具项（图标资源名 + 标签）。顺序与 H5 workspaceItems 对齐；My Guardian 为主播只读列表。
    /// Party Data 入口暂时隐藏，页面实现保留待后续恢复。
    private var tools: [(icon: String, label: String)] {
        var arr: [(icon: String, label: String)] = [
            ("toolWorkingGuide", L10n.toolWorkingGuide),
            ("toolGoLive", L10n.toolGoLive),
            ("toolMatch", L10n.toolMatch),
            ("toolTask", L10n.toolTask),
            ("toolBeauty", L10n.toolBeauty),
            ("toolBeautyCamera", L10n.toolBeautyCamera),
            ("toolPoints", L10n.toolPoints),
            ("toolGiftMessage", L10n.toolGiftMessage),
            ("toolProfileUpdate", L10n.toolProfileUpdate),
            ("toolInvite", L10n.toolInvite),
            ("toolBackpack", L10n.toolProps),
            ("toolLiveData", L10n.toolLiveData),
            // H5 Work 页使用 guardian.myGuardians（复数），与入口所展示的守护者列表一致。
            ("toolMyGuardian", L10n.guardianMyGuardians),
        ]
        // 107 Party-only 账号不应通过工作台看到私密付费内容、虚拟道具或守护者权益。
        if !permission.canVirtualItems || !permission.canGiftSending {
            let restrictedIcons: Set<String> = ["toolGiftMessage", "toolBackpack", "toolMyGuardian"]
            arr.removeAll { restrictedIcons.contains($0.icon) }
        }
        if showNewbie { arr.append(("toolNewbie", L10n.toolNewbie)) }
        arr.append(("toolBigR", L10n.toolStarUser))
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
                    // P 项目：userType 命中 .live bit 时不渲染入口
                    if tools[i].icon == "toolGoLive" {
                        if permission.canLive {
                            Button { quickGoLive.perform() } label: { cell }
                                .buttonStyle(.plain)
                        }
                    // Match → 切到 Home + Match top tab（对齐首页 Match 入口，与 CGoMatchButton 同一入口）
                    // P 项目：userType 命中 .call bit 时不渲染入口
                    } else if tools[i].icon == "toolMatch" {
                        if permission.canCall {
                            Button { openHomeMatch.perform() } label: { cell }
                                .buttonStyle(.plain)
                        }
                    // Task → Phase C 占位（B-F 阶段替换真页面）
                    } else if tools[i].icon == "toolTask" {
                        NavigationLink(value: WorkRoute.task) { cell }
                            .buttonStyle(.plain)
                    // Beauty → 美颜设置页（K-spec-美颜设置页 §0.4 Q1；生产入口）
                    } else if tools[i].icon == "toolBeauty" {
                        Button {
                            openBeautyPage(mode: .settings)
                        } label: {
                            cell
                        }
                            .buttonStyle(.plain)
                    // Beauty Camera -> the same beauty controls with a live capture action.
                    } else if tools[i].icon == "toolBeautyCamera" {
                        Button {
                            openBeautyPage(mode: .camera)
                        } label: {
                            cell
                        }
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
                    // Work 工具入口必须单独归因，不能与 Mine/Profile 入口混为 me。
                    } else if tools[i].icon == "toolInvite" {
                        NavigationLink(value: WorkRoute.invite(source: .work)) { cell }
                            .buttonStyle(.plain)
                    // Anchor Guide → 内嵌 H5 功能页
                    } else if tools[i].icon == "toolWorkingGuide" {
                        NavigationLink(value: WorkRoute.anchorGuide) { cell }
                            .buttonStyle(.plain)
                    // Live Data → Phase B 占位（下一个开工）
                    // P 项目权限管理 v2：canLive=false 时不渲染入口
                    } else if tools[i].icon == "toolLiveData" {
                        if permission.canLive {
                            NavigationLink(value: WorkRoute.liveData) { cell }
                                .buttonStyle(.plain)
                        }
                    // Party Data 暂时隐藏：入口和页面均保留注释，后续恢复时接回 WorkRoute.partyData。
                    // My Guardian → 主播自己的守护者全屏榜单（只读，无购买链路）
                    } else if tools[i].icon == "toolMyGuardian" {
                        NavigationLink(value: WorkRoute.myGuardian) { cell }
                            .buttonStyle(.plain)
                    // Newbie / Star User → 占位（页面本身留 J 里程碑落地）
                    } else if tools[i].icon == "toolNewbie" {
                        NavigationLink(value: WorkRoute.newbie) { cell }
                            .buttonStyle(.plain)
                    } else if tools[i].icon == "toolBigR" {
                        NavigationLink(value: WorkRoute.bigR) { cell }
                            .buttonStyle(.plain)
                    } else if tools[i].icon == "toolBackpack" {
                        // H · Props（虚拟道具）· 对齐 H5 work/index.vue:148 href='/virtualProps'
                        NavigationLink(value: WorkRoute.props) { cell }
                            .buttonStyle(.plain)
                    } else {
                        cell
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(Theme.Metric.cardPadding)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bigCard, style: .continuous))
        .overlay {
            if showBeautyPermissionAlert {
                MediaPermissionDialog(
                    requirement: .camera,
                    onCancel: {
                        showBeautyPermissionAlert = false
                        pendingBeautyMode = nil
                    },
                    onConfirm: retryBeautyCameraPermission
                )
            }
        }
    }

    private func openBeautyPage(mode: BeautySettingsView.Mode) {
        pendingBeautyMode = mode
        Task { @MainActor in
            guard await MediaPermissionGate.requestAccess(for: .camera) else {
                showBeautyPermissionAlert = true
                return
            }
            pendingBeautyMode = nil
            path.append(WorkRoute.beautySettings(mode: mode))
        }
    }

    private func retryBeautyCameraPermission() {
        Task { @MainActor in
            guard await MediaPermissionGate.requestAccess(for: .camera) else {
                MediaPermissionGate.openAppSettings()
                return
            }
            showBeautyPermissionAlert = false
            let mode = pendingBeautyMode ?? .settings
            pendingBeautyMode = nil
            path.append(WorkRoute.beautySettings(mode: mode))
        }
    }

    // MARK: - 单个工具
    private func toolCell(icon: String, label: String) -> some View {
        VStack(spacing: 8) {
            if icon == "toolBeautyCamera" {
                beautyCameraToolIcon
            } else {
                CDNAssetImage(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Theme.Metric.toolTile, height: Theme.Metric.toolTile)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(Theme.Typography.toolLabel)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if icon == "toolInvite" {
                earnMoneyTag
                    .offset(y: -6)   // H5 top--6 relative to tool cell
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The camera symbol is an iOS 16 SF Symbol already used elsewhere in the app;
    /// keeping it local avoids depending on a CDN asset that may not exist yet.
    private var beautyCameraToolIcon: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Theme.Metric.toolTile, height: Theme.Metric.toolTile)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    /// H5 style: linear-gradient(90deg,#F8A72E 0%,#FF4343 100%)，7pt 字，圆角 5，46×13
    private var earnMoneyTag: some View {
        Text(L10n.inviteEarnMoney)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .frame(minWidth: 46)
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

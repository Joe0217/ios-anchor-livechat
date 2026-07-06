import SwiftUI

/// 工具区：标题行 + 4 列工具图标网格。对齐 H5 work/index.vue workspaceItems。
/// Invite 图标顶部悬浮"Earn Money"金色渐变角标（H5 style）。
/// Online 开关已改为 WorkView 悬浮层，不再放本区。
struct ToolsSection: View {
    // 无 vm 依赖：tools/columns 全为 let 常量，DEBUG 分支读单例。
    // 上一版从 header 移除 Online 开关后，vm 参数变成死订阅（触发 WorkViewModel
    // 任一 @Published 变化都让 12 图标网格重算）。审查报告-202607061550 必修-1。

    /// 工具项（图标资源名 + 标签）。顺序与 H5 一致。
    /// 未接入 Newbie/bigR 后端 visible 接口，本次不展示；里程碑 J 补齐。
    private let tools: [(icon: String, label: String)] = [
        ("toolHi", L10n.toolHi),
        ("toolGoLive", L10n.toolGoLive),
        ("toolMatch", L10n.toolMatch),
        ("toolTask", L10n.toolTask),
        ("toolBeauty", L10n.toolBeauty),
        ("toolPoints", L10n.toolPoints),
        ("toolGiftMessage", L10n.toolGiftMessage),
        ("toolProfileUpdate", L10n.toolProfileUpdate),
        ("toolInvite", L10n.toolInvite),
        ("toolWorkingGuide", L10n.toolWorkingGuide),
        ("toolBackpack", L10n.toolBackpack),
        ("toolLiveData", L10n.toolLiveData),
    ]

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
                        NavigationLink(value: WorkRoute.liveSettings) { cell }
                            .buttonStyle(.plain)
                    // Beauty → 美颜设置页（K-spec-美颜设置页 §0.4 Q1；生产入口）
                    } else if tools[i].icon == "toolBeauty" {
                        NavigationLink(value: WorkRoute.beautySettings) { cell }
                            .buttonStyle(.plain)
                    // Gift Message → 私密媒体解锁页（H-2-spec-私密媒体解锁；生产入口）
                    } else if tools[i].icon == "toolGiftMessage" {
                        NavigationLink(value: WorkRoute.giftMessage) { cell }
                            .buttonStyle(.plain)
                    } else {
                        #if DEBUG
                        // DEBUG 临时入口（Release 不存在）：
                        //   Hi     → locale 切换 sheet（i18n 任务）
                        //   Invite → push POC 调试台（沿用 WorkView 的 NavigationStack）
                        if tools[i].icon == "toolHi" {
                            Button { DebugLocaleStore.shared.showSheet = true } label: { cell }
                                .buttonStyle(.plain)
                        } else if tools[i].icon == "toolInvite" {
                            NavigationLink(value: WorkRoute.pocDebug) { cell }
                                .buttonStyle(.plain)
                        } else {
                            cell
                        }
                        #else
                        cell
                        #endif
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

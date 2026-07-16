import SwiftUI

/// 单张用户卡片：左侧圆形头像（带绿色在线点）+ 中部 [昵称 / 等级行 / 位置行] + 右侧动作按钮组。
/// 字段对齐 H5 `views/home/components/list.vue` 模板；按钮组规则对齐 H5 `CCommunicationBtns`。
struct LiveListUserCard: View {
    let anchor: LiveListAnchor
    /// 是否显示视频通话按钮（对齐 H5：online segment 看 `anchortCallAuth`，prime segment 强制显示）。
    /// 由 `LiveListView` 派生：`segment == .prime || CallAuthBridge.canCall`。
    let showVideoCall: Bool

    @Environment(\.openChat) private var openChat

    var body: some View {
        // H-0：整 cell 包 NavigationLink 推入 UserProfileView。actionButton 用 .buttonStyle(.borderless)
        // 嵌套使其独立响应 tap 不冒泡到外层 NavigationLink（spec §5.3 + R-F9）。
        NavigationLink(value: UserProfileRoute.userId(anchor.userId)) {
            HStack(spacing: 12) {
                avatar
                infoColumn
                Spacer(minLength: 4)
                actionButtonGroup
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(height: Theme.Metric.liveListCardHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.liveListCard, style: .continuous)
                    .fill(Theme.Palette.liveListCardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.liveListCard, style: .continuous)
                    .strokeBorder(Theme.Palette.liveListCardBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// 按钮组：videoCall 条件显示 + chat 常显（对齐 H5 flex gap-10 并排）
    private var actionButtonGroup: some View {
        HStack(spacing: 10) {
            if showVideoCall {
                LiveListActionButton(action: .videoCall) {
                    Task { await initiateVideoCall() }
                }
                .buttonStyle(.borderless)
            }
            LiveListActionButton(action: .chat) {
                guard let id = anchor.yxAccid, !id.isEmpty else { return }
                openChat.perform(id)
            }
            .buttonStyle(.borderless)
        }
    }

    /// 圆形头像 + 右下绿色在线圆点。走公共 `AvatarView`；nil/失败自动回退用户默认头像。
    private var avatar: some View {
        AvatarView(
            urlString: anchor.icon,
            size: Theme.Metric.liveListAvatarSize,
            kind: .user,
            showsOnlineDot: true
        )
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(anchor.nickname)
                .font(Theme.Typography.liveListUserName)
                .foregroundStyle(Theme.Palette.liveListUserName)
                .lineLimit(1)
                .truncationMode(.tail)

            // 等级 / VIP 行：userLevel != "0" 才显示 Lv 徽章；vipExpireTime > 当前才显示 VIP 徽章
            HStack(spacing: 4) {
                if anchor.hasLevelBadge {
                    Image("liveListLevelIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text("Lv.\(anchor.userLevel ?? "")")
                        .font(Theme.Typography.liveListMeta)
                        .foregroundStyle(Theme.Palette.liveListUserMeta)
                }
                if anchor.hasVipBadge {
                    VIPBadge(size: .medium)
                        .accessibilityHidden(true)
                }
            }

            // 位置行
            if let country = anchor.country, !country.isEmpty {
                HStack(spacing: 4) {
                    Image("liveListLocation")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(country)
                        .font(Theme.Typography.liveListMeta)
                        .foregroundStyle(Theme.Palette.liveListLocationText)
                }
            }
        }
    }

    private var accessibilityText: String {
        var parts = [anchor.nickname]
        if anchor.hasLevelBadge, let lv = anchor.userLevel { parts.append("Lv.\(lv)") }
        if let c = anchor.country, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: ", ")
    }

    // MARK: - 拨打通话

    /// code-review Finding 5：preflight (isSignalingReady + state==.idle) 已内部化到 CallStore.callOut。
    /// 此处只需调 callOut；失败反馈由 CallStore.lastError 承载，LiveList 场景无 toast infra，仅 log。
    @MainActor
    private func initiateVideoCall() async {
        await CallStore.shared.callOut(remoteUserId: anchor.userId)
        if CallStore.shared.state == .idle, !CallStore.shared.lastError.isEmpty {
            AppLogger.call.error("[LiveList] callOut failed instantly: \(CallStore.shared.lastError, privacy: .public)")
        }
    }
}

import SwiftUI

/// 派对房「排麦申请列表」sheet — 对齐 H5
/// `livechat-h5/src/components/party/components/seat-apply-popup.vue` +
/// 安卓 `MicApplicationListDialog`。
///
/// **双视角**（对齐安卓 §5 tvConfirm 按 myIndex > 0 显示"申请/放弃"）：
/// - 房主/房管：每条 row 显示 Approve/Reject 按钮；顶部右上角显示铃铛开关切换
/// - 观众：row 只读；底部 CTA 按 myApplyInfo.inIndex > 0 显示"放弃申请" / "申请上麦"
///
/// spec §2 + §4 A3/R6/R7/R11 + list-refresh-preserve-items rule：
/// - `.task` 首次拉取（reason=.initial）
/// - `.refreshable` 下拉刷新（reason=.refresh，保留 items 视觉；await 到任务完成，spinner 不闪）
/// - `.refreshing([items])` 状态与 `.loaded` 视觉一致，仅 SwiftUI 自带顶部 spinner 表达"刷新中"
struct PartyMicApplicationSheet: View {
    @ObservedObject var store: PartyStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    /// spec §2 房主端 A4：Owner tap switch toggle → 上层弹 SwitchConfirmSheet 走首次协议 or 直接调 API
    /// 观众视角 hidden。closure 由 PartyRoomView 层接 activeRoomTool = .micApplicationSwitchConfirm
    var onTapSwitchToggle: (() -> Void)? = nil
    /// 观众"放弃申请"成功后 dismiss sheet（对齐安卓 §3.7 giveUpApplyMic → dismiss）
    /// 由 PartyRoomView 层设置为 `activeRoomTool = nil`
    var onDismissAfterCancel: (() -> Void)? = nil
    /// 对齐安卓 §3.2 showMicApplicationListDialog(seatIndex)：观众 tap 空位后待申请的 seatIndex；
    /// CTA "申请上麦"点击时消费此值调 applyMic；nil 表示当前非由 tap 空位打开（如手动开面板）
    var pendingApplySeatIndex: Int? = nil
    /// 观众"申请上麦"点击后清 pending（避免重复消费）；由 PartyRoomView 层清 `pendingApplySeatIndex = nil`
    var onDidSubmitApply: (() -> Void)? = nil
    /// 房主/房管 tap row "Approve" 时上抛（对齐安卓 SeatRosterDialog）：由 PartyRoomView 打开选座 sheet
    /// 非 nil 时按钮走上抛路径；nil 时保持旧的自动挑首空位 fallback（向后兼容）
    var onTapApprove: ((PartyMicApplication) -> Void)? = nil

    /// 是否为房主/房管视角（决定 row Actions 与底部 CTA 显示）
    private var isManagerView: Bool {
        store.selfRole == .owner || store.selfRole == .admin
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                contentArea
                // 观众视角底部 CTA：对齐安卓 tvConfirm（myIndex>0 → 放弃 / else → 申请）
                if !isManagerView {
                    audienceCTA
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await store.loadMicApplications(reason: .initial)
        }
    }

    // MARK: - Audience CTA (观众视角)

    @ViewBuilder private var audienceCTA: some View {
        // 排队中：显示"放弃申请"；未排队：显示"申请上麦"（需先在空位 tap 触发 applyMic 才有 inIndex）
        // 未排队时按钮 disabled + 提示语（观众打开 sheet 但未在队列的边界）
        let inQueue = store.myApplyInfo.inIndex > 0
        let hasPending = pendingApplySeatIndex != nil
        let ctaText: String = inQueue
            ? L10n.Party.micApplicationCancel
            : (hasPending ? L10n.Party.micApplicationSubmit : L10n.Party.micApplicationTapEmptySeatHint)
        let enabled = inQueue || hasPending
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.08))
            Button {
                if inQueue {
                    Task {
                        await store.cancelMyMicApplication()
                        // 对齐安卓 §3.7 giveUpApplyMic → dismiss；成功清 inIndex 后由上层关 sheet
                        await MainActor.run { onDismissAfterCancel?() }
                    }
                } else if let idx = pendingApplySeatIndex {
                    // 对齐安卓 tvConfirm "申请上麦"：Sheet 内手动点击才发 API
                    Task {
                        await store.applyMic(seatIndex: idx)
                        await MainActor.run { onDidSubmitApply?() }
                    }
                }
            } label: {
                Text(ctaText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        Capsule().fill(enabled
                                       ? Color(red: 0.21, green: 0.14, blue: 0.67)
                                       : Color.white.opacity(0.12))
                    )
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
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
                // H5 `seat-apply-popup.vue`：服务端权威申请数 + “people apply”。
                Text(String(format: L10n.Party.micApplicationPeopleApplyFormat, store.queueSeatNum))
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
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
            avatar(item: item)
            middleInfo(item: item)
                .frame(maxWidth: .infinity, alignment: .leading)
            // 观众视角只读，不显示 Approve/Reject 按钮（对齐安卓 MicApplicationListDialog:235-237）
            if isManagerView {
                actions(item: item)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func avatar(item: PartyMicApplication) -> some View {
        let headFrame = permission.canVirtualItems ? item.headFrame : nil
        let hasHeadFrame = headFrame?.isEmpty == false
        // 静态框由 AvatarView 统一渲染；SVGA 使用 HeadFrameView 的动画分流。
        if let headFrame, HeadFrameView.isSVGAURL(headFrame) {
            ZStack {
                AvatarView(urlString: item.avatar, size: 40, kind: .user,
                           userId: item.userId)
                HeadFrameView(urlString: headFrame, size: 52)
                    .allowsHitTesting(false)
            }
            .frame(width: 52, height: 52)
        } else {
            AvatarView(
                urlString: item.avatar,
                size: 40,
                kind: .user,
                headwearURL: headFrame,
                headwearRatio: hasHeadFrame ? 52.0 / 40.0 : 1,
                userId: item.userId
            )
            .frame(width: 52, height: 52)
        }
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
                    VIPBadge(size: .medium)
                }
                UserLevelBadge(levelName: item.levelName, size: .small)
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

    // v25：VIP 徽章统一走公共组件 VIPBadge（[Sources/DesignSystem/Badges/VIPBadge.swift]），
    // 原自定义 Text("VIP") + 橙金 gradient capsule 版本已废弃。

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

            // Approve（primary，紫底填充）
            // 对齐安卓 SeatRosterDialog(isAgreeOnSeatMode=true)：若上层传 onTapApprove 则打开选座 sheet
            // 让房主手动挑麦位；否则 fallback 到 seatIndex=nil 自动挑首空位（旧行为）
            Button {
                if let onApprove = onTapApprove {
                    onApprove(item)
                } else {
                    Task {
                        await store.agreeMicApplication(userId: item.userId, seatIndex: nil)
                    }
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

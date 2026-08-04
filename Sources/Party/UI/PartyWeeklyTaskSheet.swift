import SwiftUI

/// Android WeekTaskDialog 对齐：宝石目标进度、奖励宝石数与礼物流水。
struct PartyWeeklyTaskSheet: View {
    let roomId: String
    @ObservedObject var store: PartyWeeklyTaskStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if permission.canPartyActivities {
                taskContent
            } else {
                Color.clear.onAppear(perform: dismissIfActivitiesAreDisabled)
            }
        }
        .onChange(of: permission.canPartyActivities, perform: handleActivitiesPermissionChange)
    }

    private var taskContent: some View {
        VStack(spacing: 0) {
            header
            progressCard
            giftHistory
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .task(id: roomId) {
            guard permission.canPartyActivities else { return }
            await store.load()
        }
    }

    private func handleActivitiesPermissionChange(_ allowed: Bool) {
        guard !allowed else { return }
        dismissIfActivitiesAreDisabled()
    }

    private func dismissIfActivitiesAreDisabled() {
        guard !permission.canPartyActivities else { return }
        store.stopTracking(roomId: roomId)
        dismiss()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.PartyRoom.weeklyTaskTitle)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Text(L10n.PartyRoom.weeklyTaskGiftHistory)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }
            Spacer()
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.commonClose)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 5) {
                    CDNAssetImage("coins")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text(L10n.PartyRoom.weeklyTaskReward)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.82))
                Spacer()
                Text("+\(store.rewardQuantity)")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(hex: 0xFFFFD35C))
            }
            ProgressView(value: store.progressFraction)
                .tint(Color(hex: 0xFF9C4DFF))
            HStack {
                Text("\(store.currentProgress) / \(store.targetValue)")
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                Spacer()
                CDNAssetImage("coins")
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var giftHistory: some View {
        if store.isLoading && store.giftHistory.isEmpty {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.giftHistory.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "gift")
                    .font(.system(size: 34))
                    .foregroundColor(.white.opacity(0.35))
                Text(L10n.PartyRoom.weeklyTaskEmpty)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
                if store.hasLoadError {
                    Button(L10n.Party.retry) {
                        Task { await store.load() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFFFD35C))
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.giftHistory, content: giftRow)
                    if store.hasMore {
                        Button {
                            Task { await store.load(reset: false) }
                        } label: {
                            Group {
                                if store.isLoadingMore { ProgressView().tint(.white) }
                                else { Text(L10n.PartyRoom.weeklyTaskLoadMore) }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(hex: 0xFFFFD35C))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .refreshable { await store.load() }
        }
    }

    private func giftRow(_ item: PartyGiftHistory) -> some View {
        HStack(spacing: 10) {
            AvatarView(urlString: item.avatar, size: 36, kind: .user)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.nickname.isEmpty ? L10n.anonymous : item.nickname)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("x\(item.num)")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.58))
            }
            Spacer()
            if let icon = item.giftIcon, !icon.isEmpty {
                CachedAsyncImage(url: URL(string: icon), contentMode: .fit, cdn: (.gift, .fit)) { Color.clear }
                    .frame(width: 30, height: 30)
            }
            Text("+\(item.gemValue)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(hex: 0xFFFFD35C))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.08)) }
    }
}

/// TopX 热门房任务规则与麦时档位时间轴。
struct PartyHotRoomTaskSheet: View {
    let status: PartyHotRoomTaskStatus?
    let ruleImageURL: String?
    let topRankLimit: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.PartyRoom.hotTaskMissionRules)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if let status, status.isActive {
                ScrollView {
                    missionRuleContent(status)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "flame")
                        .font(.system(size: 34))
                        .foregroundColor(Color(hex: 0xFFFF8B3D))
                    Text(outOfTopText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
    }

    @ViewBuilder
    private func missionRuleContent(_ status: PartyHotRoomTaskStatus) -> some View {
        if let ruleImageURL,
           let url = URL(string: ruleImageURL),
           url.scheme != nil {
            CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                fallbackMissionRuleContent(status)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
        } else {
            fallbackMissionRuleContent(status)
        }
    }

    private func fallbackMissionRuleContent(_ status: PartyHotRoomTaskStatus) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            howToRewardRule
            micTimeRule(status)
            missionTimeline(status)
            giftsOnMicRule
            notesRule
        }
        .padding(18)
    }

    private var howToRewardRule: some View {
        ruleCard(marker: "Q", tint: Color(hex: 0xFFFFD35C)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.PartyRoom.hotTaskHowToReward)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(String(format: L10n.PartyRoom.hotTaskHowToRewardDetailFormat, topRankLimit))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func micTimeRule(_ status: PartyHotRoomTaskStatus) -> some View {
        ruleCard(imageName: "pinkClock", tint: Color(hex: 0xFF55C6FF)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L10n.PartyRoom.hotTaskMicTime)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(Self.durationText(status.liveValue))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Color(hex: 0xFF75D6FF))
                }
                Text(L10n.PartyRoom.hotTaskMicTimeDetail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.72))
            }
        }
    }

    private var giftsOnMicRule: some View {
        ruleCard(imageName: "partyIconGift", tint: Color(hex: 0xFFFF9B36)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.PartyRoom.hotTaskGiftsOnMic)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text(L10n.PartyRoom.hotTaskGiftsOnMicDetail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    private var notesRule: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.PartyRoom.hotTaskNotes)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(hex: 0xFFFFD35C))
            Text(L10n.PartyRoom.hotTaskNotesDetail)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func ruleCard<Content: View>(
        marker: String? = nil,
        imageName: String? = nil,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(0.2))
                    .frame(width: 30, height: 30)
                if let imageName {
                    CDNAssetImage(imageName)
                        .resizable()
                        .renderingMode(.template)
                        .foregroundColor(tint)
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else if let marker {
                    Text(marker)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(tint)
                }
            }
            content()
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func missionTimeline(_ status: PartyHotRoomTaskStatus) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(status.anchorTasks.enumerated()), id: \.element.id) { index, task in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(status.liveValue >= task.liveTime ? Color(hex: 0xFFFFD35C) : Color(hex: 0xFF55C6FF))
                            .frame(width: 12, height: 12)
                        if index < status.anchorTasks.count - 1 {
                            Rectangle()
                                .fill(Color(hex: 0xFF55C6FF).opacity(0.48))
                                .frame(width: 2, height: 60)
                        }
                    }
                    Text(Self.durationText(task.liveTime))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 56, alignment: .leading)
                    taskRewardCard(task)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private func taskRewardCard(_ task: PartyAnchorTask) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(hex: 0xFF32106E))
                    .frame(width: 50, height: 50)
                taskRewardIcon(task)
                    .frame(width: 31, height: 31)
                Text("+\(task.rewardValue)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(hex: 0xFFFF7846), in: Capsule())
                    .offset(x: 8, y: -7)
            }
            Text(task.rewardName ?? (task.rewardType == 3 ? L10n.PartyRoom.hotTaskFrame : L10n.PartyRoom.hotTaskGems))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 68)
            if let effectiveHours = task.effectiveHours, effectiveHours > 0 {
                Text(String(format: L10n.PartyRoom.hotTaskValidHours, effectiveHours))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: 0xFFFFD35C))
            }
        }
    }

    @ViewBuilder
    private func taskRewardIcon(_ task: PartyAnchorTask) -> some View {
        if let iconURL = task.rewardAsset?.iconURL, let url = URL(string: iconURL) {
            CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) {
                defaultRewardIcon(rewardType: task.rewardType)
            }
        } else {
            defaultRewardIcon(rewardType: task.rewardType)
        }
    }

    @ViewBuilder
    private func defaultRewardIcon(rewardType: Int?) -> some View {
        if rewardType == 3 {
            CDNAssetImage("homeCpAvatarFrame")
                .resizable()
                .scaledToFit()
        } else {
            CDNAssetImage("partyGems")
                .resizable()
                .scaledToFit()
        }
    }

    static func durationText(_ seconds: Int) -> String {
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var outOfTopText: String {
        String(format: L10n.PartyRoom.hotTaskOutOfTopFormat, max(1, topRankLimit))
    }
}

enum PartyTopRoomBonusDialogKind {
    case enterTopRoom
    case outOfTop
}

/// 安卓主播端 TopX 视频奖励引导的两种居中弹窗。
struct PartyTopRoomBonusDialog: View {
    let kind: PartyTopRoomBonusDialogKind
    let guide: PartyHotRoomGuide
    let topRankLimit: Int
    let onDismiss: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.68))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
                .padding(.trailing, 8)

                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        if guide.rewards.isEmpty {
                            guideRewardIcon(name: "partyGems", title: L10n.PartyRoom.hotTaskGems)
                            guideRewardIcon(name: "homeCpAvatarFrame", title: L10n.PartyRoom.hotTaskFrame)
                        } else {
                            ForEach(Array(guide.rewards.enumerated()), id: \.offset) { _, reward in
                                guideRewardIcon(reward)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(height: 92)
                .padding(.top, 18)
                .padding(.bottom, 20)

                switch kind {
                case .enterTopRoom:
                    Button(String(format: L10n.PartyRoom.topRoomBonusEnterFormat, topRankLimit), action: onConfirm)
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(primaryButtonBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .outOfTop:
                    HStack(spacing: 12) {
                        Button(L10n.PartyRoom.hotRoomGuideStay, action: onDismiss)
                            .buttonStyle(.plain)
                            .foregroundColor(.white.opacity(0.8))
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button(String(format: L10n.PartyRoom.topRoomBonusJumpFormat, topRankLimit), action: onConfirm)
                            .buttonStyle(.plain)
                            .foregroundColor(.white)
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(primaryButtonBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 320)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .padding(.horizontal, 24)
        }
    }

    private var title: String {
        switch kind {
        case .enterTopRoom:
            return L10n.PartyRoom.topRoomBonusEnterTitle
        case .outOfTop:
            return String(format: L10n.PartyRoom.topRoomBonusOutTitleFormat, topRankLimit)
        }
    }

    private var message: String {
        switch kind {
        case .enterTopRoom:
            return String(format: L10n.PartyRoom.topRoomBonusEnterSubtitleFormat, topRankLimit)
        case .outOfTop:
            return L10n.PartyRoom.topRoomBonusOutMessage
        }
    }

    private var primaryButtonBackground: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func guideRewardIcon(name: String, title: String) -> some View {
        VStack(spacing: 5) {
            CDNAssetImage(name)
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
        }
        .frame(width: 71, height: 82)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func guideRewardIcon(_ reward: PartyHotTaskRewardConfig) -> some View {
        VStack(spacing: 5) {
            if reward.rewardType == 0 {
                CDNAssetImage("partyGems")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
            } else if let iconURL = reward.iconURL, let url = URL(string: iconURL) {
                CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) {
                    guideDefaultRewardIcon(rewardType: reward.rewardType)
                }
                .frame(width: 50, height: 50)
            } else {
                guideDefaultRewardIcon(rewardType: reward.rewardType)
                    .frame(width: 50, height: 50)
            }
            Text(reward.rewardName.isEmpty
                 ? (reward.rewardType == 3 ? L10n.PartyRoom.hotTaskFrame : L10n.PartyRoom.hotTaskGems)
                 : reward.rewardName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(1)
        }
        .frame(width: 71, height: 82)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func guideDefaultRewardIcon(rewardType: Int?) -> some View {
        CDNAssetImage(rewardType == 3 ? "homeCpAvatarFrame" : "partyGems")
            .resizable()
            .scaledToFit()
    }
}

struct PartyHotTaskRewardSheet: View {
    let notification: PartyHotTaskRewardNotification
    let onDismiss: () -> Void
    @State private var isClaiming = false

    var body: some View {
        VStack(spacing: 14) {
            rewardIcon(notification.rewards.first)
                .frame(width: 64, height: 64)
            Text(L10n.PartyRoom.hotTaskRewardTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            ScrollView(showsIndicators: notification.rewards.count > 3) {
                VStack(spacing: 10) {
                    ForEach(Array(notification.rewards.enumerated()), id: \.offset) { _, reward in
                        HStack(spacing: 9) {
                            rewardIcon(reward)
                                .frame(width: 26, height: 26)
                            Text(reward.name.isEmpty ? L10n.PartyRoom.weeklyTaskRewardFallback : reward.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer()
                            Text("+\(reward.amount)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Color(hex: 0xFFFFD35C))
                        }
                        if let effectiveHours = reward.effectiveHours, effectiveHours > 0 {
                            Text(String(format: L10n.PartyRoom.hotTaskValidHours, effectiveHours))
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.62))
                        }
                    }
                }
            }
            .frame(maxHeight: 124)
            Button(action: claimReward) {
                Group {
                    if isClaiming {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(L10n.PartyRoom.hotTaskClaim)
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Color(hex: 0xFE00DE), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(isClaiming)
        }
        .frame(maxWidth: 300)
        .padding(20)
        .background(Color(hex: 0x1A0033), in: RoundedRectangle(cornerRadius: 8))
    }

    private func claimReward() {
        guard !isClaiming else { return }
        isClaiming = true
        // 1023 表示服务端已经发放奖励；Claim 仅确认当前通知并推进队列。
        onDismiss()
    }

    @ViewBuilder
    private func rewardIcon(_ reward: PartyHotTaskReward?) -> some View {
        if let iconURL = reward?.rewardAsset?.iconURL, let url = URL(string: iconURL) {
            CachedAsyncImage(url: url, contentMode: .fit, cdn: (.gift, .fit)) {
                defaultRewardIcon(rewardType: reward?.rewardType)
            }
        } else {
            defaultRewardIcon(rewardType: reward?.rewardType)
        }
    }

    @ViewBuilder
    private func defaultRewardIcon(rewardType: Int?) -> some View {
        if rewardType == 3 {
            CDNAssetImage("homeCpAvatarFrame")
                .resizable()
                .scaledToFit()
        } else {
            CDNAssetImage("partyGems")
                .resizable()
                .scaledToFit()
        }
    }
}

struct PartyHotTaskRewardOverlay: View {
    let notification: PartyHotTaskRewardNotification
    let onDismiss: () -> Void
    @ObservedObject private var permission = SelfPermissionBridge.shared

    var body: some View {
        if permission.canPartyActivities {
            ZStack {
                Color.black.opacity(0.62).ignoresSafeArea()
                PartyHotTaskRewardSheet(notification: notification, onDismiss: onDismiss)
                    .id(notification.id)
            }
            .zIndex(1_000)
        }
    }
}

/// 所有 Party 任务 sheet/奖励覆盖层集中挂载，避免房间主 View 再增加 modal 链。
struct PartyWeeklyTaskUIModifier: ViewModifier {
    @ObservedObject var weeklyStore: PartyWeeklyTaskStore
    @ObservedObject var hotStore: PartyHotRoomTaskStore
    @ObservedObject private var permission = SelfPermissionBridge.shared
    @Binding var isWeeklyTaskPresented: Bool
    @Binding var isHotTaskPresented: Bool
    let onHotTaskDismiss: () -> Void
    let roomId: String

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isWeeklyTaskPresented) {
                if permission.canPartyActivities {
                    PartyWeeklyTaskSheet(roomId: roomId, store: weeklyStore)
                        .giftPanelSheetBackground()
                        .presentationDetents([.fraction(0.5), .fraction(0.8)])
                        .presentationDragIndicator(.visible)
                } else {
                    EmptyView()
                }
            }
            .sheet(isPresented: $isHotTaskPresented, onDismiss: onHotTaskDismiss) {
                if permission.canPartyActivities {
                    PartyHotRoomTaskSheet(
                        status: hotStore.status,
                        ruleImageURL: hotStore.missionRuleImageURL,
                        topRankLimit: hotStore.topRankLimit
                    )
                        .giftPanelSheetBackground()
                        .presentationDetents([.fraction(0.5), .fraction(0.8)])
                        .presentationDragIndicator(.visible)
                } else {
                    EmptyView()
                }
            }
            .onChange(of: hotStore.shouldPresentMissionRules) { shouldPresent in
                guard permission.canPartyActivities else {
                    handleActivitiesPermissionChange(false)
                    return
                }
                if shouldPresent {
                    isHotTaskPresented = true
                    hotStore.dismissMissionRules()
                }
            }
            .overlay {
                if permission.canPartyActivities,
                   hotStore.shouldPresentProgressGuide,
                   hotStore.pendingReward == nil,
                   hotStore.rewardEffect == nil {
                    PartyHotTaskProgressGuide(topRankLimit: hotStore.topRankLimit) {
                        hotStore.dismissProgressGuide()
                    }
                }
            }
            .alert(item: Binding(
                get: { permission.canPartyActivities ? hotStore.faceVerificationWarning : nil },
                set: { if $0 == nil { hotStore.dismissFaceVerificationWarning() } }
            )) { warning in
                Alert(
                    title: Text(L10n.PartyRoom.hotTaskTitle),
                    message: Text(warning.hasReachedLimit
                                  ? L10n.PartyRoom.hotTaskFaceLimitWarning
                                  : L10n.PartyRoom.hotTaskFaceWarning),
                    dismissButton: .default(Text(L10n.Party.ok)) {
                        hotStore.dismissFaceVerificationWarning()
                    }
                )
            }
            .onChange(of: permission.canPartyActivities, perform: handleActivitiesPermissionChange)
    }

    private func handleActivitiesPermissionChange(_ allowed: Bool) {
        guard !allowed else { return }
        isWeeklyTaskPresented = false
        isHotTaskPresented = false
        weeklyStore.stopTracking(roomId: roomId)
        hotStore.stopTracking()
    }
}

/// 1023 到达后在当前麦位短暂播放宝石效果。
struct PartyWeeklyTaskRewardSeatEffect: View {
    let isSelf: Bool
    let size: CGFloat
    @ObservedObject private var store = PartyHotRoomTaskStore.shared
    @ObservedObject private var permission = SelfPermissionBridge.shared

    var body: some View {
        if permission.canPartyActivities, isSelf, let reward = store.rewardEffect {
            PartyHotTaskRewardSeatEffectView(reward: reward, size: size)
                .id(reward.id)
        }
    }
}

private struct PartyHotTaskProgressGuide: View {
    let topRankLimit: Int
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(Color(hex: 0xFFFF8B3D))
                Text(L10n.PartyRoom.hotTaskHowToReward)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text(String(format: L10n.PartyRoom.hotTaskHowToRewardDetailFormat, topRankLimit))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
                Button(action: onDismiss) {
                    Text(L10n.Party.ok)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Color(hex: 0xFE00DE), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(Color(hex: 0x1A0033), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct PartyHotTaskRewardSeatEffectView: View {
    let reward: PartyHotTaskRewardNotification
    let size: CGFloat

    var body: some View {
        if let vfxURL = reward.effectVFXURL,
           let url = URL(string: vfxURL) {
            if vfxURL.lowercased().contains(".svga") {
                RemoteSVGAImageView(
                    url: url,
                    loops: 1,
                    onFinished: {
                        Task { @MainActor in
                            PartyHotRoomTaskStore.shared.completeRewardEffect(reward.id)
                        }
                    }
                )
                    .frame(width: size, height: size)
                    .allowsHitTesting(false)
            } else {
                CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                    PartyHotTaskGemBurst(id: reward.id, size: size)
                }
                .frame(width: size, height: size)
                .allowsHitTesting(false)
            }
        } else {
            PartyHotTaskGemBurst(id: reward.id, size: size)
        }
    }
}

private struct PartyHotTaskGemBurst: View {
    let id: UUID
    let size: CGFloat
    @State private var animate = false

    var body: some View {
        CDNAssetImage("partyGems")
            .resizable().scaledToFit()
            .frame(width: size * 0.52, height: size * 0.52)
            .scaleEffect(animate ? 1.35 : 0.35)
            .opacity(animate ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1)) { animate = true }
            }
    }
}

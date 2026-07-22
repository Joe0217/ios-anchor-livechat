import SwiftUI

/// 派对房主播周任务：上麦时长累计换金币/宝石奖励。
struct PartyWeeklyTaskSheet: View {
    let roomId: String
    @ObservedObject private var store = PartyWeeklyTaskStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            liveTimeSummary
            content
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .task(id: roomId) {
            store.beginTracking(roomId: roomId)
            await store.load()
        }
    }

    private var header: some View {
        ZStack {
            Text(L10n.PartyRoom.weeklyTaskTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            HStack {
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.commonClose)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var liveTimeSummary: some View {
        VStack(spacing: 5) {
            Text(L10n.PartyRoom.weeklyTaskLiveTime)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            Text(Self.durationText(store.accumulatedLiveTime))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(Color(hex: 0xFFE600))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.tasks.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.tasks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 38))
                    .foregroundColor(.white.opacity(0.35))
                Text(L10n.PartyRoom.weeklyTaskEmpty)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.tasks) { task in
                        taskRow(task)
                    }
                    if store.hasMore {
                        Button {
                            Task { await store.load(reset: false) }
                        } label: {
                            if store.isLoadingMore {
                                ProgressView().tint(.white)
                            } else {
                                Text(L10n.PartyRoom.weeklyTaskLoadMore)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Color(hex: 0xFFE600))
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable { await store.load() }
        }
    }

    private func taskRow(_ task: PartyWeeklyTask) -> some View {
        let progress = max(task.progressLiveTime ?? 0, store.accumulatedLiveTime)
        let target = task.targetLiveTime ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text(task.title.isEmpty ? L10n.PartyRoom.weeklyTaskTitle : task.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)

            if target > 0 {
                GeometryReader { geometry in
                    let fraction = min(1, CGFloat(progress) / CGFloat(target))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.14))
                        Capsule()
                            .fill(Color(hex: 0xFE00DE))
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("\(Self.durationText(progress)) / \(Self.durationText(target))")
                    Spacer()
                    rewardText(task.rewards)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            } else {
                HStack {
                    Text(Self.durationText(progress))
                    Spacer()
                    rewardText(task.rewards)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rewardText(_ rewards: [PartyWeeklyTaskReward]) -> some View {
        if !rewards.isEmpty {
            HStack(spacing: 4) {
                Image("partyGems")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                Text(rewards.map { reward in
                    let title = reward.name.isEmpty ? L10n.PartyRoom.weeklyTaskRewardFallback : reward.name
                    return reward.amount.map { "\(title) \($0)" } ?? title
                }.joined(separator: ", "))
                    .lineLimit(1)
            }
            .foregroundColor(Color(hex: 0xFFE600))
        }
    }

    static func durationText(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

/// 热门房任务状态页。具体露脸检测和 OSS 上传契约仍需以真机接口日志确认，不能在客户端臆造上报字段。
struct PartyHotRoomTaskSheet: View {
    let status: PartyHotRoomTaskStatus?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "flame.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color(hex: 0xFFFF8B3D))
            Text(status?.title.isEmpty == false ? status!.title : L10n.PartyRoom.hotTaskTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            if let status, let current = status.current, let target = status.target, target > 0 {
                VStack(spacing: 8) {
                    ProgressView(value: Double(current), total: Double(target))
                        .tint(Color(hex: 0xFF4DB7FF))
                    Text("\(current) / \(target)")
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .presentationDetents([.fraction(0.5), .fraction(0.8)])
    }
}

struct PartyHotRoomGuideSheet: View {
    let guide: PartyHotRoomGuide
    let onSwitch: (PartyHotRoomGuide) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "flame.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(Color(hex: 0xFFFF8B3D))
            Text(L10n.PartyRoom.hotRoomGuideTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
            if !guide.roomName.isEmpty {
                Text(guide.roomName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button(L10n.Party.cancel, action: dismiss.callAsFunction)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Button(L10n.PartyRoom.hotRoomGuideAction) {
                    onSwitch(guide)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color(hex: 0xFE00DE), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }
}

/// P2P 1023 奖励到帐弹窗。服务端已发奖，按钮仅负责确认关闭。
struct PartyWeeklyTaskRewardSheet: View {
    let notification: PartyWeeklyTaskRewardNotification
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image("partyGems")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .scaleEffect(1.08)

            Text(L10n.PartyRoom.weeklyTaskRewardTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)

            VStack(spacing: 8) {
                ForEach(Array(notification.rewards.enumerated()), id: \.offset) { _, reward in
                    HStack(spacing: 8) {
                        Image("partyGems")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                        Text(reward.name.isEmpty ? L10n.PartyRoom.weeklyTaskRewardFallback : reward.name)
                        Spacer()
                        if let amount = reward.amount {
                            Text("x\(amount)")
                                .fontWeight(.bold)
                        }
                    }
                    .foregroundColor(Color(hex: 0xFFE600))
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Button(action: onDismiss) {
                Text(L10n.PartyRoom.weeklyTaskRewardConfirm)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(hex: 0xFE00DE), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 340)
        .padding(24)
        .background(Color(hex: 0x1A0033), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 将周任务两个 sheet 从 `PartyRoomView` 主 body 中拆出，避免增加房间主视图的类型检查复杂度。
struct PartyWeeklyTaskUIModifier: ViewModifier {
    @ObservedObject var store: PartyWeeklyTaskStore
    @Binding var isTaskSheetPresented: Bool
    let roomId: String

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isTaskSheetPresented) {
                PartyWeeklyTaskSheet(roomId: roomId)
                    .giftPanelSheetBackground()
                    .presentationDetents([.fraction(0.5), .fraction(0.8)])
                    .presentationDragIndicator(.visible)
                    .overlay {
                        if let notification = store.pendingReward {
                            rewardOverlay(notification)
                        }
                    }
            }
            .overlay {
                if !isTaskSheetPresented, let notification = store.pendingReward {
                    rewardOverlay(notification)
                }
            }
    }

    private func rewardOverlay(_ notification: PartyWeeklyTaskRewardNotification) -> some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
            PartyWeeklyTaskRewardSheet(notification: notification) {
                store.dismissReward(notification.id)
            }
        }
        .interactiveDismissDisabled()
    }
}

/// 安卓 `TaskRewardDialog` 前的麦位宝石动画。无论当前麦位是否仍在视图中，store 都会在固定时长后
/// 推进到奖励窗，避免座位变更时奖励提示被永久阻塞。
struct PartyWeeklyTaskRewardSeatEffect: View {
    let isSelf: Bool
    let size: CGFloat
    @ObservedObject private var store = PartyWeeklyTaskStore.shared

    var body: some View {
        if isSelf, let reward = store.rewardEffect {
            PartyWeeklyTaskGemBurst(id: reward.id, size: size)
                .id(reward.id)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct PartyWeeklyTaskGemBurst: View {
    let id: UUID
    let size: CGFloat
    @State private var visible = false

    var body: some View {
        ZStack {
            gem.offset(x: -size * 0.23, y: -size * 0.12)
            gem.offset(x: size * 0.24, y: -size * 0.2)
            gem.offset(x: 0, y: size * 0.18)
        }
        .scaleEffect(visible ? 1 : 0.2)
        .opacity(visible ? 1 : 0)
        .task(id: id) {
            visible = false
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) {
                visible = true
            }
            try? await Task.sleep(nanoseconds: 920_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                visible = false
            }
        }
    }

    private var gem: some View {
        Image("partyGems")
            .resizable()
            .scaledToFit()
            .frame(width: size * 0.52, height: size * 0.52)
    }
}

import SwiftUI

/// 独立活动抽奖页。仅由首页受信任活动 Banner 接管，不读取 PartyStore，也不要求加入房间。
struct LotteryView: View {
    @StateObject private var store: LotteryStore
    @State private var isRecordsPresented = false
    /// `getRoomId` 完成前用户可能已返回上一页；必须由页面生命周期取消，不能让迟到回包跨 Tab 跳转。
    @State private var roomNavigationTask: Task<Void, Never>?
    private let onOpenPartyRoom: (String) -> Bool
    private let onOpenLiveSettings: () -> Bool

    init(
        route: LotteryRoute,
        onOpenPartyRoom: @escaping (String) -> Bool = { _ in false },
        onOpenLiveSettings: @escaping () -> Bool = { false }
    ) {
        _store = StateObject(wrappedValue: LotteryStore(route: route))
        self.onOpenPartyRoom = onOpenPartyRoom
        self.onOpenLiveSettings = onOpenLiveSettings
    }

    var body: some View {
        ZStack {
            LotteryPageBackground(assets: store.activity?.assets)
            pageContent
        }
        .navigationTitle(store.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isRecordsPresented = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(L10n.Lottery.records)
                .disabled(store.isBusy || store.activity == nil)
            }
        }
        .task { await store.loadIfNeeded() }
        .sheet(
            isPresented: Binding(
                get: { store.isResultPresented },
                set: { if !$0 { store.dismissResult() } }
            )
        ) {
            LotteryResultSheet(
                prizes: store.resultPrizes,
                assets: store.activity?.assets,
                onClose: store.dismissResult
            )
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isRecordsPresented) {
            LotteryRecordsSheet(store: store)
        }
        .overlay {
            if store.isInsufficientPresented, let activity = store.activity {
                LotteryInsufficientPopup(
                    configuration: activity.popupConfiguration,
                    targets: activity.info.insufficientRoomTargets,
                    loadingTarget: store.roomNavigationTarget,
                    onAction: handleInsufficientAction,
                    onClose: cancelRoomNavigation
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.isInsufficientPresented)
        .onDisappear(perform: cancelRoomNavigation)
    }

    @ViewBuilder
    private var pageContent: some View {
        if let activity = store.activity {
            ScrollView {
                VStack(spacing: 16) {
                    LotteryCountdownView(
                        info: activity.info,
                        now: store.now,
                        phase: store.activityPhase
                    )

                    switch store.state {
                    case .unsupportedPrizeLayout:
                        LotteryUnavailableCard(
                            title: L10n.Lottery.unsupportedPrizeLayout,
                            action: { Task { await store.refresh() } }
                        )
                    default:
                        lotteryContent(activity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
        } else {
            initialContent
        }
    }

    @ViewBuilder
    private var initialContent: some View {
        switch store.state {
        case .failed(let message):
            LotteryUnavailableCard(
                title: message,
                action: { Task { await store.refresh() } }
            )
            .padding(.horizontal, 24)
        default:
            ProgressView()
                .tint(.white)
                .scaleEffect(1.15)
        }
    }

    private func lotteryContent(_ activity: LotteryActivity) -> some View {
        VStack(spacing: 15) {
            ZStack {
                LotteryWheelBackground(assets: activity.assets)

                VStack(spacing: 14) {
                    LotteryMarqueeView(records: store.winners)
                        LotteryPrizeGrid(
                        prizes: activity.prizes,
                        assets: activity.assets,
                        highlightedPrizeID: store.highlightedPrizeID,
                        isEnabled: store.canDraw,
                            onCenterTap: { store.startDraw(.one, entry: .center) }
                    )
                    .padding(.top, 2)

                    Text(String(format: L10n.Lottery.remainingChancesFormat, store.remainingTimes))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)

                    LotteryPointProgressView(progress: activity.pointProgress)

                    HStack(spacing: 10) {
                        LotteryDrawButton(
                            title: L10n.Lottery.oneTime,
                            imageURL: activity.assets.url(for: "button_one_select"),
                            isEnabled: store.canDraw,
                            isLoading: store.state == .submitting,
                            action: { store.startDraw(.one) }
                        )
                        LotteryDrawButton(
                            title: L10n.Lottery.fiveTimes,
                            imageURL: activity.assets.url(for: "button_five_select"),
                            isEnabled: store.canDraw,
                            isLoading: store.state == .submitting,
                            action: { store.startDraw(.five) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            let moreChancesTarget = moreChancesTarget(for: activity)
            HStack(spacing: 12) {
                Text(
                    activity.info.insufficientRoomTargets.isPartyOnly
                        ? L10n.Lottery.earnChancesPartyHint
                        : L10n.Lottery.earnChancesHint
                )
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LotteryMoreChancesButton(
                    target: moreChancesTarget,
                    isLoading: store.roomNavigationTarget == moreChancesTarget,
                    action: { openMoreChances(for: activity) }
                )
            }

            if let ruleImageURL = activity.assets.url(for: "rule_pic") {
                CachedAsyncImage(url: ruleImageURL, contentMode: .fit, persistent: true) {
                    Color.clear.frame(height: 0)
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .opacity(store.isBusy && store.state == .reconciling ? 0.72 : 1)
    }

    private func handleInsufficientAction(_ action: LotteryPopupAction) {
        switch action {
        case .goPartyRoom:
            requestRoomNavigation(for: .party)
        case .goLiveRoom:
            requestRoomNavigation(for: .live)
        case .close:
            cancelRoomNavigation()
        case .unknown:
            break
        }
    }

    private func openMoreChances(for activity: LotteryActivity) {
        guard store.activityPhase != .notStarted else {
            AppToastCenter.shared.show(L10n.Lottery.notStarted)
            return
        }
        guard !store.isBusy else {
            AppToastCenter.shared.show(L10n.Lottery.pleaseWait)
            return
        }
        requestRoomNavigation(
            for: moreChancesTarget(for: activity),
            requiresInsufficientPopup: false
        )
    }

    private func moreChancesTarget(for activity: LotteryActivity) -> LotteryRoomTarget {
        activity.info.insufficientRoomTargets.isPartyOnly ? .party : .live
    }

    private func requestRoomNavigation(for target: LotteryRoomTarget,
                                       requiresInsufficientPopup: Bool = true) {
        roomNavigationTask?.cancel()
        roomNavigationTask = Task { @MainActor in
            guard let roomID = await store.requestRoomID(
                for: target,
                requiresInsufficientPopup: requiresInsufficientPopup
            ) else {
                return
            }
            let didStartNavigation: Bool
            switch target {
            case .party:
                didStartNavigation = onOpenPartyRoom(roomID)
            case .live:
                // 返回的 live roomId 仅验证服务端存在可用直播；主播端继续走已有开播设置，
                // 不能把它构造成客态 AudienceLiveRoomRoute。
                didStartNavigation = onOpenLiveSettings()
            }
            if didStartNavigation {
                store.dismissInsufficientPopup()
            }
        }
    }

    private func cancelRoomNavigation() {
        roomNavigationTask?.cancel()
        roomNavigationTask = nil
        store.dismissInsufficientPopup()
    }
}

/// H5 `insufficient-popup.vue` 的原生实现。服务端配置图片时保留图片内的视觉设计，
/// 原生只叠加可访问、可禁用的操作热区；无配置时使用与 H5 同语义的默认引导卡。
private struct LotteryInsufficientPopup: View {
    let configuration: LotteryPopupConfiguration?
    let targets: LotteryInsufficientRoomTargets
    let loadingTarget: LotteryRoomTarget?
    let onAction: (LotteryPopupAction) -> Void
    let onClose: () -> Void

    private var usesCustomLayout: Bool {
        configuration?.usesCustomLayout == true
    }

    private var visibleCustomButtons: [LotteryPopupButton] {
        guard usesCustomLayout else { return [] }
        return (configuration?.buttons ?? []).filter { button in
            switch button.popupAction {
            case .goPartyRoom:
                return targets.showsParty
            case .goLiveRoom:
                return targets.showsLive
            case .close, .unknown:
                return true
            }
        }
    }

    private var customMainButtons: [LotteryPopupButton] {
        visibleCustomButtons.filter { $0.popupAction != .close }
    }

    private var customCloseButtons: [LotteryPopupButton] {
        visibleCustomButtons.filter { $0.popupAction == .close }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            if usesCustomLayout {
                customDialog
            } else {
                defaultDialog
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var customDialog: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(
                    url: configuration?.backgroundImageURL,
                    contentMode: .fit,
                    persistent: true
                ) {
                    Color(hex: 0x2A164E)
                        .aspectRatio(0.82, contentMode: .fit)
                }
                .frame(maxWidth: 351)
                .overlay(alignment: .bottom) {
                    if !customMainButtons.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(Array(customMainButtons.enumerated()), id: \.offset) { _, button in
                                customMainButton(button)
                            }
                        }
                        .padding(.horizontal, 25)
                        .padding(.bottom, 42)
                    }
                }

                if customCloseButtons.isEmpty {
                    closeButton
                        .padding(8)
                }
            }

            if !customCloseButtons.isEmpty {
                HStack(spacing: 16) {
                    ForEach(Array(customCloseButtons.enumerated()), id: \.offset) { _, button in
                        customCloseButton(button)
                    }
                }
            }
        }
        .frame(maxWidth: 351)
        .padding(.horizontal, 12)
    }

    private var defaultDialog: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(.bottom, -28)

            Image(systemName: "gift.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Color(hex: 0xFF9D36))
                .frame(width: 64, height: 64)
                .background(Color(hex: 0xFFE8BB), in: Circle())

            Text(L10n.Lottery.insufficientTitle)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(hex: 0x1F2933))
                .multilineTextAlignment(.center)

            Text(L10n.Lottery.insufficientMessage)
                .font(.system(size: 13))
                .foregroundStyle(Color(hex: 0x667085))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)

            if targets.showsParty {
                defaultTargetButton(target: .party)
                    .padding(.top, 8)
            }
            if targets.showsLive {
                defaultTargetButton(target: .live)
                    .padding(.top, targets.showsParty ? 0 : 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: 320)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
        .padding(.horizontal, 28)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(usesCustomLayout ? .white : Color(hex: 0x667085))
                .frame(width: 32, height: 32)
                .background(
                    usesCustomLayout ? Color.black.opacity(0.42) : Color.black.opacity(0.06),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.commonClose)
    }

    private func defaultTargetButton(target: LotteryRoomTarget) -> some View {
        let isParty = target == .party
        let isLoading = loadingTarget == target
        return Button {
            onAction(isParty ? .goPartyRoom : .goLiveRoom)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isParty ? "gift.fill" : "video.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text(isParty ? L10n.Lottery.goPartyRoom : L10n.Lottery.goLiveRoom)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.74)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                LinearGradient(
                    colors: isParty
                        ? [Color(hex: 0xFFAA3D), Color(hex: 0xFF6B2C)]
                        : [Color(hex: 0x4DA3FF), Color(hex: 0x2563EB)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || loadingTarget != nil)
        .opacity(loadingTarget == nil || isLoading ? 1 : 0.65)
        .accessibilityLabel(isParty ? L10n.Lottery.goPartyRoom : L10n.Lottery.goLiveRoom)
    }

    private func customMainButton(_ button: LotteryPopupButton) -> some View {
        let isLoading = isLoading(button.popupAction)
        return Button {
            onAction(button.popupAction)
        } label: {
            Group {
                if let imageURL = button.imageURL {
                    CachedAsyncImage(url: imageURL, contentMode: .fit, persistent: true) {
                        Color.clear
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .overlay {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(button.popupAction == .unknown || loadingTarget != nil)
        .opacity(isLoading ? 0.75 : 1)
        .accessibilityLabel(button.label.isEmpty ? L10n.Lottery.insufficientTitle : button.label)
    }

    private func customCloseButton(_ button: LotteryPopupButton) -> some View {
        Button {
            onAction(button.popupAction)
        } label: {
            Group {
                if let imageURL = button.imageURL {
                    CachedAsyncImage(url: imageURL, contentMode: .fit, persistent: true) {
                        Circle().fill(.white.opacity(0.12))
                    }
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.1), in: Circle())
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(button.label.isEmpty ? L10n.commonClose : button.label)
    }

    private func isLoading(_ action: LotteryPopupAction) -> Bool {
        switch action {
        case .goPartyRoom:
            return loadingTarget == .party
        case .goLiveRoom:
            return loadingTarget == .live
        case .close, .unknown:
            return false
        }
    }
}

private struct LotteryPageBackground: View {
    let assets: LotteryAssets?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x1A0752), Color(hex: 0x320B55), Theme.Palette.screenBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            CachedAsyncImage(
                url: assets?.url(for: "background_image"),
                contentMode: .fill,
                persistent: true
            ) {
                Color.clear
            }
            .ignoresSafeArea()
            .opacity(0.82)
        }
    }
}

private struct LotteryWheelBackground: View {
    let assets: LotteryAssets

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x4D1678), Color(hex: 0x210D4B)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            CachedAsyncImage(url: assets.url(for: "wheel_background"), contentMode: .fill, persistent: true) {
                Color.clear
            }
            .opacity(0.88)
        }
    }
}

private struct LotteryCountdownView: View {
    let info: LotteryActivityInfo
    let now: Date
    let phase: LotteryActivityPhase

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: phase == .notStarted ? "calendar.badge.clock" : "clock")
                .font(.system(size: 13, weight: .semibold))
            Text(label)
                .font(.system(size: 13, weight: .medium))
            if let target = info.countdownTarget(at: now) {
                Text(Self.timeText(until: target, now: now))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .background(Color.black.opacity(0.22), in: Capsule())
    }

    private var label: String {
        switch phase {
        case .notStarted: return L10n.Lottery.startsIn
        case .active: return L10n.Lottery.endsIn
        case .ended: return L10n.Lottery.ended
        }
    }

    private static func timeText(until target: Date, now: Date) -> String {
        let total = max(0, Int(target.timeIntervalSince(now)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

private struct LotteryMarqueeView: View {
    let records: [LotteryRewardRecord]
    @State private var currentIndex = 0

    private struct ScrollKey: Hashable {
        let ids: [String]
    }

    var body: some View {
        Group {
            if let record = visibleRecord {
                Text(displayText(for: record))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(record.id)
            } else {
                Color.clear.frame(height: 18)
            }
        }
        .frame(height: 20)
        .animation(.easeInOut(duration: 0.5), value: currentIndex)
        .task(id: ScrollKey(ids: records.map(\.id))) {
            currentIndex = 0
            guard records.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, !records.isEmpty else { return }
                currentIndex = (currentIndex + 1) % records.count
            }
        }
    }

    private var visibleRecord: LotteryRewardRecord? {
        guard !records.isEmpty else { return nil }
        return records[currentIndex % records.count]
    }

    private func displayText(for record: LotteryRewardRecord) -> String {
        let base = String(format: L10n.Lottery.winnerFormat, record.userName, record.prizeName)
        guard let detail = record.detailKind else { return base }
        return "\(base) \(lotteryPrizeDetailText(detail))"
    }
}

private struct LotteryPrizeGrid: View {
    let prizes: [LotteryPrize]
    let assets: LotteryAssets
    let highlightedPrizeID: String?
    let isEnabled: Bool
    let onCenterTap: () -> Void

    private var isNineGrid: Bool { prizes.count == 8 }
    private var columnCount: Int { isNineGrid ? 3 : 4 }
    private var unit: CGFloat { isNineGrid ? 98 : 73.5 }
    private var normalAssetURL: URL? {
        assets.url(for: isNineGrid ? "eight_grid_select" : "twelve_grid_select")
    }
    private var selectedAssetURL: URL? {
        assets.url(for: isNineGrid ? "eight_grid_selected" : "twelve_grid_selected")
    }

    var body: some View {
        ZStack {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(unit), spacing: 0), count: columnCount),
                spacing: 0
            ) {
                ForEach(Array(positionedPrizes.enumerated()), id: \.offset) { _, prize in
                    if let prize {
                        LotteryPrizeCell(
                            prize: prize,
                            normalAssetURL: normalAssetURL,
                            selectedAssetURL: selectedAssetURL,
                            isHighlighted: highlightedPrizeID == prize.displayID,
                            compact: !isNineGrid
                        )
                        .frame(width: unit, height: unit)
                    } else {
                        Color.clear.frame(width: unit, height: unit)
                    }
                }
            }
            .frame(width: 294, height: 294)

            LotteryCenterDrawButton(
                imageURL: assets.url(for: isNineGrid ? "eight_grid_centre" : "twelve_grid_centre"),
                size: isNineGrid ? 86 : 144,
                isEnabled: isEnabled,
                action: onCenterTap
            )
        }
        .frame(width: 294, height: 294)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var positionedPrizes: [LotteryPrize?] {
        let positions: [Int?]
        if isNineGrid {
            positions = [0, 1, 2, 3, nil, 4, 5, 6, 7]
        } else {
            positions = [0, 1, 2, 3, 4, nil, nil, 5, 6, nil, nil, 7, 8, 9, 10, 11]
        }
        return positions.map { index in
            guard let index, prizes.indices.contains(index) else { return nil }
            return prizes[index]
        }
    }
}

private struct LotteryPrizeCell: View {
    let prize: LotteryPrize
    let normalAssetURL: URL?
    let selectedAssetURL: URL?
    let isHighlighted: Bool
    let compact: Bool

    private var iconSize: CGFloat { compact ? 31 : 43 }
    private var titleSize: CGFloat { compact ? 10 : 12 }

    var body: some View {
        ZStack {
            CachedAsyncImage(
                url: isHighlighted ? selectedAssetURL : normalAssetURL,
                contentMode: .fill,
                persistent: true
            ) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? Color(hex: 0xFFC52D) : Color.white.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                isHighlighted ? Color.white.opacity(0.92) : Color.white.opacity(0.22),
                                lineWidth: isHighlighted ? 2 : 1
                            )
                    }
            }

            VStack(spacing: compact ? 2 : 4) {
                CachedAsyncImage(url: prize.iconURL, contentMode: .fit, persistent: true) {
                    Image(systemName: "gift.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white.opacity(0.76))
                }
                .frame(width: iconSize, height: iconSize)

                Text(prize.name)
                    .font(.system(size: titleSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: compact ? 58 : 74)

                if let detail = prize.detailKind {
                    LotteryPrizeDetailText(detail: detail, fontSize: compact ? 9 : 10)
                }
            }
            .padding(.top, compact ? 5 : 7)
            .padding(.bottom, 3)
        }
        .clipped()
    }
}

private struct LotteryCenterDrawButton: View {
    let imageURL: URL?
    let size: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let imageURL {
                    CachedAsyncImage(url: imageURL, contentMode: .fill, persistent: true) {
                        fallback
                    }
                } else {
                    fallback
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.56)
        .accessibilityLabel(L10n.Lottery.oneTime)
    }

    private var fallback: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0xFFDC53), Color(hex: 0xFF6E26)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                VStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.system(size: max(15, size * 0.22), weight: .bold))
                    Text(L10n.Lottery.draw)
                        .font(.system(size: max(10, size * 0.14), weight: .black))
                }
                .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
    }
}

private struct LotteryPointProgressView: View {
    let progress: LotteryPointProgress

    var body: some View {
        VStack(spacing: 6) {
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.brandYellow)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.24))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0xFFE769), Color(hex: 0xFF8A2B)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * progress.ratio)
                    Text("\(progress.currentPoints) / \(progress.singleLotteryPoints)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .shadow(color: .black.opacity(0.65), radius: 1, y: 1)
                }
            }
            .frame(width: 280, height: 14)
        }
    }

    private var statusText: String {
        if progress.dailyChanceReached {
            guard progress.dailyChanceLimit > 0 else {
                return L10n.Lottery.dailyLimitReached
            }
            return String(
                format: L10n.Lottery.dailyLimitFormat,
                progress.dailyChanceUsed,
                progress.dailyChanceLimit
            )
        }
        return String(format: L10n.Lottery.pointsNeededFormat, progress.pointsToNext)
    }
}

private struct LotteryDrawButton: View {
    let title: String
    let imageURL: URL?
    let isEnabled: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Group {
                    if let imageURL {
                        CachedAsyncImage(url: imageURL, contentMode: .fill, persistent: true) {
                            fallback
                        }
                    } else {
                        fallback
                    }
                }
                if isLoading {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0xFFAF31), Color(hex: 0xF65E29)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct LotteryMoreChancesButton: View {
    let target: LotteryRoomTarget
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .tint(Theme.Palette.brandYellow)
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                }
                Text(L10n.Lottery.go)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.Palette.brandYellow)
            .frame(minHeight: 30)
            .padding(.horizontal, 10)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .opacity(isLoading ? 0.72 : 1)
        .accessibilityLabel(target == .party ? L10n.Lottery.goPartyRoom : L10n.Lottery.goLiveRoom)
    }
}

private struct LotteryPrizeDetailText: View {
    let detail: LotteryPrizeDetailKind
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var text: String {
        lotteryPrizeDetailText(detail)
    }
}

private func lotteryPrizeDetailText(_ detail: LotteryPrizeDetailKind) -> String {
    switch detail {
    case .days(let days):
        return String(format: L10n.Lottery.validDaysFormat, days)
    case .quantity(let quantity):
        return String(format: L10n.Lottery.quantityFormat, quantity)
    }
}

private struct LotteryUnavailableCard: View {
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.Palette.brandYellow)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(L10n.commonRetry)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: 40)
                    .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LotteryResultSheet: View {
    let prizes: [LotteryPrize]
    let assets: LotteryAssets?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x48217A), Color(hex: 0x1A0C44)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            CachedAsyncImage(url: assets?.url(for: "popup_center"), contentMode: .fill, persistent: true) {
                Color.clear
            }
            .ignoresSafeArea()
            .opacity(0.55)

            VStack(spacing: 18) {
                Text(L10n.Lottery.congratulations)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: prizes.count > 1 ? 2 : 1),
                        spacing: 16
                    ) {
                        ForEach(prizes) { prize in
                            VStack(spacing: 8) {
                                CachedAsyncImage(url: prize.iconURL, contentMode: .fit, persistent: true) {
                                    Image(systemName: "gift.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                .frame(width: 64, height: 64)

                                Text(prize.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)

                                if let detail = prize.detailKind {
                                    LotteryPrizeDetailText(detail: detail, fontSize: 12)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 128)
                            .padding(12)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Button(action: onClose) {
                    Text(L10n.commonOK)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(hex: 0x3B144F))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Theme.Palette.brandYellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 26)
        }
        .presentationDetents([.fraction(0.72)])
        .presentationDragIndicator(.hidden)
    }
}

private struct LotteryRecordsSheet: View {
    @ObservedObject var store: LotteryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.Lottery.records)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.commonClose)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if store.records.isEmpty, !store.isLoadingRecords {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 30, weight: .light))
                    Text(L10n.Lottery.recordsEmpty)
                        .font(.system(size: 14))
                }
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.records) { record in
                            LotteryRecordRow(record: record)
                                .onAppear {
                                    if record.id == store.records.last?.id {
                                        Task { await store.loadMoreRecords() }
                                    }
                                }
                        }
                        if store.isLoadingRecords {
                            ProgressView()
                                .tint(.white)
                                .padding(.vertical, 18)
                        } else if store.isRecordsFinished, !store.records.isEmpty {
                            Text(L10n.Lottery.recordsEnd)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.vertical, 18)
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
        .background(Theme.Palette.screenBackground)
        .task { await store.reloadRecords() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct LotteryRecordRow: View {
    let record: LotteryRewardRecord

    var body: some View {
        HStack(spacing: 12) {
            Text(LotteryDateText.display(record.createdTime))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 94, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.prizeName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.brandYellow)
                    .lineLimit(1)
                if let detail = record.detailKind {
                    LotteryPrizeDetailText(detail: detail, fontSize: 11)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
        }
    }
}

private enum LotteryDateText {
    static func display(_ raw: String) -> String {
        if let value = Double(raw) {
            let seconds = value > 10_000_000_000 ? value / 1_000 : value
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        return raw
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()
}

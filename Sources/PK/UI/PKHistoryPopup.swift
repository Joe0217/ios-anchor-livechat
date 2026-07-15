import SwiftUI

/// PK 历史记录 sheet（对齐 H5 `pkHistoryPopup.vue`）。
///
/// **呈现方式**：通过 `.sheet(isPresented: $showHistory)` 挂在 PKInviteSheet 内 —
/// sheet-inside-sheet 层级 > 父 invite sheet；视觉从底部滑起（对齐 H5 `van-popup position="bottom"`）。
///
/// **UI 结构**（自上而下）：
/// - **Header**：左返回箭头 + "PK Record" 居中标题
/// - **Stats bar**：`Effective PK Win Count This Week X/Y`（含 ? 提示）
/// - **Record list**：分页拉取 pkHistory；每条 record 双方头像 + 结果标志 + 分数进度条
/// - **Footer**：`Keep last 30 days records` 提示
///
/// **iOS 简化**：
/// - H5 `pk-history-vs.webp` / `pk-history-{win/loss/draw}.webp` / `pk-history-icon.webp` /
///   `pk-history-progress-bar-bg.webp` 切图 → 用 SF Symbol + 文字 + LinearGradient 兜底
/// - `?` popover 提示直接用 iOS alert (`.alert()`) 替代
struct PKHistoryPopup: View {
    @Binding var isPresented: Bool
    @StateObject private var store = PKRecordStore()
    @State private var showEffectiveTip: Bool = false

    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statsBar
            listArea
            footer
        }
        .background(
            LinearGradient(colors: [Color(hex: 0x5300A1),
                                    Color(hex: 0x3800A0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .task { store.onAppear() }
        // TODO i18n: 外部工具反复 revert `pk.record.*` L10n keys；暂用硬编码英文让 build 通过，
        // 待查明 linter 干扰源后正式接入 L10n.PK.recordXxx
        .alert("Effective wins",
               isPresented: $showEffectiveTip) {
            Button(L10n.liveRoomPermissionAlertOK, role: .cancel) {}
        } message: {
            Text("Number of PK matches won with PK score above the effective threshold this week.")
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            Text(L10n.PK.historyTitle)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)

            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .overlay(Divider().background(Color.white.opacity(0.1)), alignment: .bottom)
    }

    // MARK: - Stats bar（Effective PK Win Count This Week）

    private var statsBar: some View {
        HStack(spacing: 4) {
            Text("Effective PK Win Count This Week")   // TODO i18n: L10n.PK.recordEffectiveWinLabel
                .font(.system(size: 13))
                .foregroundColor(.white)
            if store.totalPkCount > 0 {
                Text("\(store.validWinCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFE600))
                Text("/\(store.totalPkCount)")
                    .font(.system(size: 13))
                    .foregroundColor(.white)
            } else {
                Text("-")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: 0xFFE600))
            }
            Button { showEffectiveTip = true } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .overlay(Divider().background(Color.white.opacity(0.1)), alignment: .bottom)
    }

    // MARK: - List area
    // v23（2026-07-13 修滚动跳顶）：**不用 switch 分派 recordList** —— switch 里 `.loaded` 与 `.loadingMore` 分支
    // 被 SwiftUI 视为不同位置的 view，state 转换会 dismantle + 重建 ScrollView 致滚动 reset。改 if 链把两态
    // **合并到同一分支** 渲染 recordList（view identity 稳定）——参 [swiftui-camera-preview §1]

    /// 派生列表参数：把 `.loaded` / `.loadingMore` / `.refreshing` 归并到同一元组，保证
    /// 同一个 `recordList(...)` 调用点在三态之间只是参数变化而非 view 重建（对齐 [swiftui-camera-preview §1]）
    private var derivedListState: (records: [PKRecordItem], hasMore: Bool, isLoadingMore: Bool) {
        switch store.state {
        case .loaded(let r, let hm, _):    return (r, hm, false)
        case .loadingMore(let r, _):       return (r, true, true)
        case .refreshing(let r):           return (r, false, false)   // 保留旧 items 视觉，顶部 spinner 由 .refreshable 系统管
        default:                           return ([], false, false)
        }
    }

    @ViewBuilder
    private var listArea: some View {
        let derived = derivedListState
        if case .error = store.state {
            errorView
        } else if case .idle = store.state {
            loadingView
        } else if case .loading = store.state {
            loadingView
        } else {
            // `.loaded` / `.loadingMore` / `.refreshing` 全走这一分支，只参数变化 → view identity 稳定
            recordList(derived.records,
                       hasMore: derived.hasMore,
                       isLoadingMore: derived.isLoadingMore)
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer(minLength: 40)
            ProgressView().tint(.white)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange.opacity(0.8))
            Text(L10n.liveRoomContributionErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            Button(action: { Task { await store.refresh() } }) {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recordList(_ records: [PKRecordItem], hasMore: Bool, isLoadingMore: Bool) -> some View {
        Group {
            if records.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 15) {
                        // v24（2026-07-13 修上拉失效）：**用"最后一行 onAppear" 触发 loadMore**（对齐 PKInviteSheet
                        // recommendList 已有做法）。旧的 sentinel Color.clear.onAppear 只在首次进视口触发一次，
                        // 加载完成后 sentinel 位置不离开视口 → onAppear 不重触发 → 无法继续加载。
                        // 改成最后一行 onAppear：records.count 变化 → "最后一行"是新 view identity → onAppear 重触发
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            PKHistoryRow(record: record)
                                .onAppear {
                                    if index == records.count - 1, hasMore, !isLoadingMore {
                                        store.loadMoreIfNeeded()
                                    }
                                }
                        }
                        if hasMore && isLoadingMore {
                            HStack {
                                ProgressView().tint(.white.opacity(0.7))
                            }
                            .frame(height: 40)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
                }
                .refreshable { await store.refresh() }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text(L10n.PK.rankSheetEmpty)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Keep last 30 days records")   // TODO i18n: L10n.PK.recordKeepDaysFooter
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .overlay(Divider().background(Color.white.opacity(0.1)), alignment: .top)
    }
}

// MARK: - PKHistoryRow

private struct PKHistoryRow: View {
    let record: PKRecordItem

    var body: some View {
        VStack(spacing: 8) {
            Text(formatTime(record.startTime))
                .font(.system(size: 13))
                .foregroundColor(.white)

            HStack(spacing: 0) {
                mySide
                vsIcon
                oppositeSide
            }

            progressBar
        }
        .padding(12)
        .background(
            LinearGradient(colors: [Color.white.opacity(0.10),
                                    Color.white.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    // MARK: - My side

    private var mySide: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                AvatarView(urlString: record.avatar, size: 44, kind: .anchor)
                    .overlay(Circle().stroke(Color(hex: 0xFF9DEA), lineWidth: 2))
                resultBadge
                    .offset(x: -8, y: -8)
            }
            Text(record.nickname ?? "Me")   // TODO i18n: L10n.PK.recordSelfDefault
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 结果标志：win/loss/draw（H5 pk-history-{win/loss/draw}.webp 切图 → 用 SwiftUI Capsule + 色兜底）
    private var resultBadge: some View {
        Group {
            switch record.resultType {
            case .win:
                Text(L10n.PK.resultWin)
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(hex: 0xFFBB02), in: Capsule())
            case .loss:
                Text(L10n.PK.resultLose)
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(hex: 0x9E9E9E), in: Capsule())
            case .draw:
                Text(L10n.PK.resultDraw)
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(hex: 0x00B8FF), in: Capsule())
            }
        }
    }

    // MARK: - VS icon（H5 pk-history-vs.webp → 渐变文字 "VS"）

    private var vsIcon: some View {
        Text("VS")
            .font(.system(size: 18, weight: .black, design: .rounded))
            .foregroundStyle(
                LinearGradient(colors: [Color(hex: 0xFF0090), Color(hex: 0x0055FF)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: 44, height: 44)
    }

    // MARK: - Opposite side

    private var oppositeSide: some View {
        VStack(spacing: 8) {
            AvatarView(urlString: record.oppositeAvatar, size: 44, kind: .anchor)
                .overlay(Circle().stroke(Color(hex: 0x69BCFF), lineWidth: 2))
            Text(record.oppositeNickname ?? "")
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Progress bar（我方粉→对方蓝分色进度 + 双方分数）

    private var progressBar: some View {
        GeometryReader { geo in
            let (myPct, _) = pkValuePercentages()
            let barWidth = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x2099FC), Color(hex: 0x0055FF)],
                                         startPoint: .leading, endPoint: .trailing))
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0xFF0090), Color(hex: 0xFF3CC4)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: barWidth * CGFloat(myPct) / 100)
                HStack {
                    HStack(spacing: 2) {
                        Image("livePkIcon")
                            .resizable().frame(width: 12, height: 12)
                        Text("\(record.pkCounter)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: 0xFFE600))
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        Text("\(record.oppositePkCounter)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: 0xFFE600))
                        Image("livePkIcon")
                            .resizable().frame(width: 12, height: 12)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: 20)
    }

    /// 双方分数占比（clamp 17-83 避免文字被进度条边界遮挡；对齐 H5 pkHistoryPopup L83）
    private func pkValuePercentages() -> (my: Int, opp: Int) {
        let my = record.pkCounter
        let opp = record.oppositePkCounter
        let total = my + opp
        guard total > 0 else { return (50, 50) }
        let myPct = max(17, min(83, Int(round(Double(my) / Double(total) * 100))))
        return (myPct, 100 - myPct)
    }

    // MARK: - Time format（对齐 H5 dayjs 'DD/MM/YYYY HH:mm'）

    private func formatTime(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: date)
    }
}

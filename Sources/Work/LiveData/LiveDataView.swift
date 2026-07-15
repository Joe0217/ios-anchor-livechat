import SwiftUI

/// Phase B —— 直播数据页（对齐 H5 `views/liveData/index.vue`）。
///
/// 视觉结构：期间 tab（Weekly/Monthly）+ 汇总卡（含子期间下拉 + 展开分档）+ 倒计时（当前期间才显）
/// + 日期列表（每行独立 collapse）+ 右下浮标 moneyBag。
///
/// 状态机：见 [LiveDataStore.State]（idle → loading → loaded / error，切期间保留 previous）。
struct LiveDataView: View {
    @StateObject private var vm = LiveDataStore()
    /// 子期间下拉菜单展开态（限制 UI 层，不进 store —— 短生命周期 UI 状态）
    @State private var showDropdown = false
    /// 规则 sheet 展示态（对齐 H5 CNavBar right question 图标点开推 /liveRule 页；iOS 用 sheet）
    @State private var showRuleSheet = false

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
            // dropdown layer(open 时挂):内部 ZStack —— catcher base + dropdown menu top,
            // 确保 dropdown Button 优先响应 tap(catcher 在下不会吞 tap)
            if showDropdown {
                dropdownLayer
            }
            moneyBagLayer
        }
        .navigationTitle(L10n.liveDataNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.screenBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showRuleSheet = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(L10n.liveDataRuleNavTitle)
            }
        }
        .sheet(isPresented: $showRuleSheet) {
            LiveRuleSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // 未 hide back button，iOS 默认 swipe-to-pop 生效，无需显式挂 .swipeToPopEnabled()
        // dropdown 展开/收起动画 —— .transition 需要外层 .animation(_:value:) 才生效
        .animation(.easeInOut(duration: 0.25), value: showDropdown)
        .task { vm.onAppear() }
    }

    // MARK: content
    /// ScrollView 只在一个位置出现（swiftui-camera-preview rule §1：switch 内重复子 view 会
    /// 触发 dismantle+重建 → scroll position 丢失 + 每行 @State expanded 全 reset）。
    /// 用 ZStack + if 分支 + overlay 保 ScrollView identity 稳定。
    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .top) {
            if let payload = vm.state.currentPayload {
                ScrollView { mainStack(payload: payload) }
                    .scrollIndicators(.hidden)
            } else if case .error = vm.state {
                fullScreenError
            } else {
                fullScreenLoading
            }

            // overlay：仅在有 previous payload 时才叠加（无 previous 时是 fullScreen 变体）
            if vm.state.currentPayload != nil {
                if vm.state.isLoading {
                    overlaySpinner
                } else if vm.state.errorMessage != nil {
                    errorBanner
                }
            }
        }
    }

    private func mainStack(payload: LiveDataResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            segmentHeader
                .padding(.top, 14)

            LiveDataSummaryCard(
                dateType: vm.dateType,
                totalDurationSeconds: payload.totalDurationSecondsCount,
                totalIncomeDiamonds: payload.totalIncomeDiamondsCount,
                liveIncomeDiamonds: payload.liveIncomeDiamondsCount,
                privateCallIncomeDiamonds: payload.privateCallIncomeDiamondsCount,
                onDropdownTap: { showDropdown.toggle() },
                dropdownExpanded: showDropdown
            )

            // "Detail Data" 标题仅在 dataList 存在时显示(对齐 H5 index.vue:260 `v-if="dataList"`;
            //  dataList=[] 是 truthy 仍显示，dataList=null/缺失时不显示)
            if payload.dataList != nil {
                Text(L10n.liveDataDetailData)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.top, 10)
            }

            if vm.dateType.isCurrent {
                LiveDataCountdownRow(totalSeconds: payload.remainingTime)
            }

            // LazyVStack：monthly 期间 dataList 可能 30 天，惰性 realize 视口内避免全部提前布局。
            // ForEach id 用 statDate 防止后端若 id 是每期间自增序号 1-N 导致 SwiftUI 残留态。
            // expanded 从 Store expandedDates 读取，reload 成功时批量清空（对齐 H5 `item.openStatus = false`）
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(payload.dataList ?? [], id: \.statDate) { day in
                    LiveDataDateRow(
                        day: day,
                        isExpanded: vm.expandedDates.contains(day.statDate),
                        onToggle: { vm.toggleExpanded(day.statDate) }
                    )
                }
            }

            Color.clear.frame(height: 40)  // 底部留白避浮标
        }
        .padding(.horizontal, 16)
    }

    // MARK: segment tabs（Weekly / Monthly，右上）
    private var segmentHeader: some View {
        HStack {
            Text(L10n.liveDataTotalData)
                .font(.system(size: 15))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 15) {
                ForEach(LiveDataDateType.Segment.allCases, id: \.self) { seg in
                    segmentPill(seg)
                }
            }
        }
    }

    private func segmentPill(_ seg: LiveDataDateType.Segment) -> some View {
        let active = vm.dateType.segment == seg
        return Button {
            // 切 segment 时子期间归位到该 segment 首项（对齐 H5 handleTabClick 里 showDownUpValue = 0）
            // 用 tapDateType 对齐 H5 无条件 getData 语义（点已选 segment 也 reload）
            let first = LiveDataDateType.children(of: seg).first ?? .thisWeek
            vm.tapDateType(first)
            showDropdown = false
        } label: {
            Text(seg == .weekly ? L10n.commonWeekly : L10n.commonMonthly)
                .font(.system(size: 10))
                .foregroundStyle(active ? Color(hex: 0xFFE600) : .white.opacity(0.5))
                .frame(width: 54, height: 26)
                .overlay(
                    Capsule().stroke(
                        active ? Color(hex: 0xFFE600) : .white.opacity(0.5),
                        lineWidth: 1
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 子期间下拉菜单层(含全屏 catcher + 菜单)
    /// dropdown 打开时挂到 body ZStack layer 3。内部 ZStack: catcher(base 全屏)+ menu(top 相对屏 topTrailing)。
    /// 菜单绝对定位:相对 safe area topTrailing —— top padding = mainStack top(14) + segmentHeader(26) +
    /// VStack spacing(10) + SummaryCard header top padding(12) + header 高度(~30) + 空隙(~8) = ~100pt；
    /// trailing padding = mainStack.horizontal(16) + dropdown 在 SummaryCard 内的 trailing(12) = 28pt。
    @ViewBuilder
    private var dropdownLayer: some View {
        ZStack(alignment: .topTrailing) {
            // catcher(base 全屏,点空白关 dropdown)
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showDropdown = false
                    }
                }

            // dropdown menu(top layer,z 高于 catcher → Button 优先响应)
            let children = LiveDataDateType.children(of: vm.dateType.segment)
            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, ct in
                    Button {
                        vm.tapDateType(ct)
                        showDropdown = false
                    } label: {
                        Text(label(for: ct))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                vm.dateType == ct
                                    ? Color(hex: 0x8978A8)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .frame(width: 120)
            .background(Color(hex: 0x625678))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            // 吞下 dropdown 内空白区 tap，阻止冒泡到 base catcher（对齐 H5 index.vue:178 `@click.stop=""`）
            // 若不加，用户 tap Button 间隙 4pt padding 会误关 dropdown（反直觉）
            .contentShape(Rectangle())
            .onTapGesture { /* 拦截,不做任何事 */ }
            .padding(.top, 100)
            .padding(.trailing, 28)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func label(for dt: LiveDataDateType) -> String {
        switch dt {
        case .thisWeek:     return L10n.commonThisWeek
        case .lastWeek:     return L10n.commonLastWeek
        case .thisMonth:    return L10n.commonThisMonth
        case .lastMonth:    return L10n.commonLastMonth
        case .twoMonthsAgo: return L10n.commonTwoMonthsAgo
        }
    }

    // MARK: 浮标
    private var moneyBagLayer: some View {
        LiveDataMoneyBag(sureGetAward: vm.sureGetAward, onTap: openTask)
    }

    /// 跳 Task 页（当前是 ComingSoon 占位；Phase C 上线后自动指向真页面）。
    /// iOS 无法从当前 push 页再 push 平级页 —— 需父 NavigationPath；由 env 注入 handler。
    @Environment(\.moneyBagAction) private var moneyBagAction
    private func openTask() {
        // 跳 Task 前关 dropdown —— 否则 pop 回来时 dropdown 残留(SwiftUI @StateObject 保留 state)
        if showDropdown { showDropdown = false }
        moneyBagAction?()
    }

    // MARK: - loading / error 变体
    private var fullScreenLoading: some View {
        VStack {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var overlaySpinner: some View {
        HStack {
            Spacer()
            ProgressView().tint(.white)
                .padding(8)
                .background(.black.opacity(0.4))
                .clipShape(Circle())
            Spacer()
        }
        .padding(.top, 60)
    }

    private var fullScreenError: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.7))
            Text(vm.state.errorMessage ?? L10n.commonNetworkError)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                vm.reload()
            } label: {
                Text(L10n.commonRetry)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorBanner: some View {
        Text(vm.state.errorMessage ?? L10n.commonNetworkError)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: 0xE40132).opacity(0.9))
            .clipShape(Capsule())
            .padding(.top, 60)
            .onTapGesture { vm.reload() }
    }
}

// MARK: - Environment: money bag tap action

private struct MoneyBagActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var moneyBagAction: (() -> Void)? {
        get { self[MoneyBagActionKey.self] }
        set { self[MoneyBagActionKey.self] = newValue }
    }
}

#Preview {
    NavigationStack {
        LiveDataView()
            .environment(\.moneyBagAction, { print("moneyBag tap (preview stub)") })
    }
    .preferredColorScheme(.dark)
}

import SwiftUI

/// Party Data 主看板 —— 对齐安卓 [PartyRoomDataActivity]（analysis §3.1）。
///
/// 视觉/操作镜像 [LiveDataView]，差异：
/// - dateType 4 值（无 twoMonthsAgo）
/// - 收入分档 2 项 UI（合并 Partycall 计费+礼物）
/// - 总麦时 & 每日行麦时可点 → 弹麦时二级页 sheet
/// - **无浮标 moneyBag**
/// - 倒计时行复用 [LiveDataCountdownRow]（`totalSeconds` 参数无 live 语义强绑定）
struct PartyDataView: View {
    @StateObject private var vm = PartyDataStore()
    @State private var showDropdown = false
    @State private var showRuleSheet = false
    @State private var micTimeContext: MicTimeDetailContext?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
            if showDropdown {
                dropdownLayer
            }
        }
        .navigationTitle(L10n.partyDataNavTitle)
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
                .accessibilityLabel(L10n.partyDataRuleNavTitle)
            }
        }
        .sheet(isPresented: $showRuleSheet) {
            PartyRuleSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $micTimeContext) { ctx in
            PartyMicTimeDetailView(dateType: ctx.dateType, statDate: ctx.statDate)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .animation(.easeInOut(duration: 0.25), value: showDropdown)
        .task { vm.onAppear() }
    }

    // MARK: content
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

            if vm.state.currentPayload != nil {
                if vm.state.isLoading {
                    overlaySpinner
                } else if vm.state.errorMessage != nil {
                    errorBanner
                }
            }
        }
    }

    private func mainStack(payload: PartyDataBoardResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            segmentHeader
                .padding(.top, 14)

            PartyDataSummaryCard(
                dateType: vm.dateType,
                micTimeSeconds: payload.micTimeSeconds,
                totalIncomeGems: payload.totalIncomeGems,
                incomeBreakdown: payload.incomeBreakdown,
                onDropdownTap: { showDropdown.toggle() },
                dropdownExpanded: showDropdown,
                onMicTimeTap: {
                    // 总麦时点 → 周期维度（statDate=nil）
                    micTimeContext = MicTimeDetailContext(dateType: vm.dateType, statDate: nil)
                }
            )

            // "Detail Data" 标题仅在 dailyList 存在时显示
            if payload.dailyList != nil {
                Text(L10n.liveDataDetailData)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.top, 10)
            }

            // 倒计时：当前期间 + countdownSeconds > 0（复用 LiveDataCountdownRow）
            if vm.dateType.isCurrent && payload.countdownSeconds > 0 {
                LiveDataCountdownRow(totalSeconds: payload.countdownSeconds)
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(payload.dailyList ?? [], id: \.statDate) { day in
                    PartyDataDateRow(
                        day: day,
                        isExpanded: vm.expandedDates.contains(day.statDate),
                        onToggle: { vm.toggleExpanded(day.statDate) },
                        onMicTimeTap: {
                            // 日行麦时点 → 单日维度（带 statDate）
                            micTimeContext = MicTimeDetailContext(dateType: vm.dateType, statDate: day.statDate)
                        }
                    )
                }
            }

            Color.clear.frame(height: 40)
        }
        .padding(.horizontal, 16)
    }

    // MARK: segment tabs
    private var segmentHeader: some View {
        HStack {
            Text(L10n.liveDataTotalData)
                .font(.system(size: 15))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 15) {
                ForEach(PartyDataDateType.Segment.allCases, id: \.self) { seg in
                    segmentPill(seg)
                }
            }
        }
    }

    private func segmentPill(_ seg: PartyDataDateType.Segment) -> some View {
        let active = vm.dateType.segment == seg
        return Button {
            let first = PartyDataDateType.children(of: seg).first ?? .thisWeek
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

    // MARK: dropdown layer
    @ViewBuilder
    private var dropdownLayer: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showDropdown = false
                    }
                }

            let children = PartyDataDateType.children(of: vm.dateType.segment)
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
            .contentShape(Rectangle())
            .onTapGesture { }
            .padding(.top, 100)
            .padding(.trailing, 28)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func label(for dt: PartyDataDateType) -> String {
        switch dt {
        case .thisWeek:  return L10n.commonThisWeek
        case .lastWeek:  return L10n.commonLastWeek
        case .thisMonth: return L10n.commonThisMonth
        case .lastMonth: return L10n.commonLastMonth
        }
    }

    // MARK: loading / error 变体
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

/// 麦时二级页 sheet context —— `Identifiable` 让 `.sheet(item:)` 每次值变换重弹（新周期/新日）
struct MicTimeDetailContext: Identifiable {
    let id = UUID()
    let dateType: PartyDataDateType
    let statDate: String?
}

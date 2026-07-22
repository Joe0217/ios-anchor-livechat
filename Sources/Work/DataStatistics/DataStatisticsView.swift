import SwiftUI

/// Work 顶部 Detail 的数据统计页，对齐 H5 `views/dataStatistics/index.vue`。
struct DataStatisticsView: View {
    @StateObject private var store = DataStatisticsStore()
    @State private var showDislikeInfo = false
    @State private var showDeduction = false

    var body: some View {
        ZStack {
            Theme.Palette.screenBackground.ignoresSafeArea()
            content
        }
        .navigationTitle(L10n.dataStatisticsNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.screenBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showDislikeInfo) {
            StatisticsInfoSheet(
                title: L10n.dataStatisticsDislikeRate,
                message: L10n.dataStatisticsDislikeRateDescription
            )
            .giftPanelSheetBackground()
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDeduction, onDismiss: { }) {
            DeductionSheet(store: store)
                .giftPanelSheetBackground()
                .presentationDetents([.height(315)])
                .presentationDragIndicator(.visible)
                .task { await store.loadDeductionCondition() }
        }
        .task { await store.onAppear() }
    }

    @ViewBuilder
    private var content: some View {
        if let dashboard = store.state.dashboard {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    banner
                    dislikeSection(dashboard.preview)
                    weeklyLevelSection(dashboard.levelInfo)
                    benefitsSection(dashboard.benefits)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.reload() }
            .overlay {
                if store.state.isLoading {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
        } else if case .error(let message, _) = store.state {
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button(L10n.commonRetry) { Task { await store.reload() } }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
        } else {
            ProgressView().tint(.white)
        }
    }

    private var banner: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.dataStatisticsNavTitle)
                    .font(.system(size: 18, weight: .semibold))
                Text(L10n.dataStatisticsBannerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 92)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x6021BD), Color(hex: 0xE40132)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 20)
    }

    private func dislikeSection(_ preview: DataStatisticsPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L10n.dataStatisticsTotalDislikeRate) {
                Button { showDeduction = true } label: {
                    Text(L10n.dataStatisticsOffsetDislike)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                statisticsCard(value: preview.likes, title: L10n.dataStatisticsLikes, icon: "hand.thumbsup.fill", color: Color(hex: 0xFF6A45))
                statisticsCard(value: preview.dislikes, title: L10n.dataStatisticsDislikes, icon: "hand.thumbsdown.fill", color: Color(hex: 0x37CAFF))
                statisticsCard(value: DataStatisticsFormatter.percentage(preview.dislikeRate), title: L10n.dataStatisticsDislikeRate, icon: "chart.bar.fill", color: Color(hex: 0x61FF93))
            }
        }
        .padding(.top, 20)
    }

    private func weeklyLevelSection(_ level: DataStatisticsLevelInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L10n.workWeeklyLevel) {
                Text(L10n.dataStatisticsPrivateAndLiveOnly)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            VStack(spacing: 0) {
                levelRow(L10n.dataStatisticsCategory, L10n.dataStatisticsWeek, L10n.commonLastWeek, isHeader: true)
                Divider().overlay(Color.black.opacity(0.4)).padding(.vertical, 12)
                levelRow(L10n.dataStatisticsLevelAnswerRate, DataStatisticsFormatter.percentage(level.answerRateThisWeek), DataStatisticsFormatter.percentage(level.answerRateLastWeek))
                levelRow(L10n.dataStatisticsLevelAvgDuration, DataStatisticsFormatter.duration(level.avgDurationThisWeek), DataStatisticsFormatter.duration(level.avgDurationLastWeek))
                levelRow(L10n.dataStatisticsLevelCalls, level.callsThisWeek, level.callsLastWeek)
                levelRow(L10n.dataStatisticsLevelUpdateTime, level.updateTimeThisWeek, level.updateTimeLastWeek)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Theme.Palette.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.top, 20)
    }

    private func benefitsSection(_ benefits: DataStatisticsBenefits) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L10n.dataStatisticsCurrentLevelBenefits) { EmptyView() }
            VStack(spacing: 8) {
                ForEach(benefits.available, id: \.self) { benefit in
                    benefitRow(benefit, available: true)
                }
                ForEach(benefits.unavailable, id: \.self) { benefit in
                    benefitRow(benefit, available: false)
                }
            }
            .padding(16)
            .background(Theme.Palette.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.top, 20)
    }

    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            if title == L10n.dataStatisticsTotalDislikeRate {
                Button { showDislikeInfo = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.dataStatisticsDislikeRate)
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.bottom, 2)
    }

    private func statisticsCard(value: String, title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(2)
                .frame(height: 30, alignment: .topLeading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func levelRow(_ category: String, _ week: String, _ lastWeek: String, isHeader: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(category).frame(maxWidth: .infinity, alignment: .leading)
            Text(week).frame(maxWidth: .infinity)
            Text(lastWeek).frame(maxWidth: .infinity)
        }
        .font(.system(size: isHeader ? 14 : 13, weight: isHeader ? .medium : .regular))
        .foregroundStyle(isHeader ? Color(hex: 0xFFE600) : .white)
        .padding(.vertical, isHeader ? 0 : 9)
    }

    private func benefitRow(_ benefit: String, available: Bool) -> some View {
        HStack(spacing: 10) {
            Text(benefit)
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(available ? Color(hex: 0x61FF93) : Theme.Palette.textSecondary)
        }
    }
}

private struct StatisticsInfoSheet: View {
    let title: String
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.leading)
            Button { dismiss() } label: {
                Text(L10n.commonConfirm)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)], startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }
}

private struct DeductionSheet: View {
    @ObservedObject var store: DataStatisticsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.dataStatisticsRemoveDislike)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(L10n.dataStatisticsRemoveDislikeDescription)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
            if store.isLoadingCondition {
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 56)
            } else if let condition = store.deductionCondition {
                HStack {
                    Text(L10n.dataStatisticsCurrentPoints)
                    Spacer()
                    Text(condition.points)
                }
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .medium))
                Text(String(format: L10n.dataStatisticsRemainingChancesFormat, condition.pointsRequired, condition.remainingChances))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Button {
                Task {
                    let succeeded = await store.submitDeduction()
                    if succeeded {
                        AppToastCenter.shared.show(L10n.dataStatisticsDeductionSucceeded)
                        dismiss()
                    } else {
                        AppToastCenter.shared.show(L10n.dataStatisticsDeductionUnavailable)
                    }
                }
            } label: {
                Group {
                    if store.isSubmittingDeduction { ProgressView().tint(.white) }
                    else { Text(L10n.dataStatisticsOffset) }
                }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(store.deductionCondition?.canDeduct != true || store.isSubmittingDeduction)
            .opacity(store.deductionCondition?.canDeduct == true ? 1 : 0.5)
        }
        .padding(24)
    }
}

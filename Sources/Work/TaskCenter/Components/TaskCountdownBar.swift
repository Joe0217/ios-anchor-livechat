import SwiftUI
import Combine

/// 任务重置倒计时卡。对齐设计稿:**粉紫渐变**整卡 + 左侧闪电 + "Task Reset:" + "5days" + 3 紫色小色块 HH:MM:SS。
///
/// - Daily:客户端派生 Asia/Shanghai 今晚 23:59:59(CLAUDE.md 时区约束)
/// - Weekly:服务端 `weeklyResetRemainSeconds` 递减(设计稿有 5days,支持天数)
struct TaskCountdownBar: View {
    let cycle: TaskCycle
    let weeklyServerRemainSeconds: Int
    let weeklyTotalPoints: Int?
    let onWeeklyReset: () -> Void

    @State private var remaining: Int = 0
    @State private var timerCancellable: AnyCancellable?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                    Text(L10n.taskResetPrefix)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 8)

                countdownBlocks
            }

            if cycle == .weekly {
                Divider()
                    .overlay(Color.black.opacity(0.4))
                    .padding(.vertical, 8)
                HStack(spacing: 6) {
                    CDNAssetImage("homeRankIntegral")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                    Text(L10n.taskWeeklyTotalPointsLabel)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Text("\(weeklyTotalPoints ?? 0)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xF640DC), Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { startTicking() }
        .onDisappear { timerCancellable?.cancel() }
        .onChange(of: cycle) { _ in startTicking() }
        .onChange(of: weeklyServerRemainSeconds) { _ in
            if cycle == .weekly { startTicking() }
        }
    }

    /// D days + H : M : S
    private var countdownBlocks: some View {
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let mins = (remaining % 3600) / 60
        let secs = remaining % 60
        return HStack(spacing: 6) {
            if days > 0 {
                Text(String(format: L10n.taskDaysFormat, days))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            HStack(spacing: 4) {
                block(String(format: "%02d", hours))
                colon
                block(String(format: "%02d", mins))
                colon
                block(String(format: "%02d", secs))
            }
        }
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 24)
            .background(Color(hex: 0x8515FF).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
    }

    private func startTicking() {
        timerCancellable?.cancel()
        remaining = initialRemaining()
        guard remaining > 0 else { return }
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if remaining > 1 {
                    remaining -= 1
                } else {
                    remaining = 0
                    timerCancellable?.cancel()
                    timerCancellable = nil
                    if cycle == .weekly {
                        onWeeklyReset()
                    }
                }
            }
    }

    private func initialRemaining() -> Int {
        if cycle == .weekly {
            return max(0, weeklyServerRemainSeconds)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let start = cal.startOfDay(for: now)
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return max(0, Int(tomorrow.timeIntervalSince(now)))
    }
}

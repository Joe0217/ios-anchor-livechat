import SwiftUI
import Combine

/// 倒计时行：仅当子期间为 this week / this month 时显示（对齐 H5 `value === 'this'`）。
/// 显示格式：`Time Remaining: N days HH:MM:SS`（N days + 3 个色块 HH/MM/SS）。
struct LiveDataCountdownRow: View {
    /// 剩余秒数（后端 `remainingTime` 直接传入，秒）
    let totalSeconds: Int

    @State private var remaining: Int = 0
    @State private var timerCancellable: AnyCancellable?

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                Text(L10n.liveDataTimeRemaining)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Spacer()

            countdownBlocks
        }
        .padding(12)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            remaining = max(0, totalSeconds)
            startTicking()
        }
        .onDisappear { timerCancellable?.cancel() }
        .onChange(of: totalSeconds) { newValue in
            remaining = max(0, newValue)
        }
    }

    // MARK: countdown blocks（N days + H : M : S）
    private var countdownBlocks: some View {
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let mins = (remaining % 3600) / 60
        let secs = remaining % 60

        return HStack(spacing: 4) {
            Text("\(days) \(L10n.liveDataDays)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            block(String(format: "%02d", hours))
            colon
            block(String(format: "%02d", mins))
            colon
            block(String(format: "%02d", secs))
        }
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Color(hex: 0x7C3EDD))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(hex: 0xFA06F4))
    }

    private func startTicking() {
        timerCancellable?.cancel()
        // 1s tick；到 0 停止（H5 van-count-down 同款行为）
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if remaining > 0 { remaining -= 1 }
            }
    }
}

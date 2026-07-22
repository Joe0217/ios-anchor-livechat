import SwiftUI

/// 直播间任务面板通用进度条 —— Tab1/Tab2 共用尺寸(h14 w220 max-w218 bg#332D87),
/// 只有内层填充色差异(Tab1 粉红 / Tab2 金橙)。
///
/// 对齐 H5:
/// - liveGiftTaskTab.vue L108-114 外框 `h-14 w-220 rounded-10 bg-#332D87`,内层 `h12 max-w218 rounded-20`
/// - liveGiftTaskTab.vue L172-176 CSS `.progress-bar { transition: all 1s ease; width: 0 }`(粉红渐变)
/// - activeTycoonTaskTab.vue L75-79 同尺寸,内层金橙渐变
///
/// **动画机制**(spec §3.3 v2 修订):
/// - `@State displayRatio` 初始 0
/// - `.task` 触发 0→targetRatio(easeOut 1s)—— 首次挂载视觉从 0 撑起
/// - `.onChange(targetRatio)` 触发平滑过渡 —— IM 到达 giftTask 更新时
struct LiveGiftProgressBar: View {
    let currentPoints: Int64
    let totalPoints: Int64
    let innerGradientColors: [Color]
    /// H5 Live Gift Tab 在 nextTick 后延迟 3 秒开始进度动画；Tycoon Tab 不延迟。
    let initialAnimationDelayNanoseconds: UInt64

    init(currentPoints: Int64,
         totalPoints: Int64,
         innerGradientColors: [Color],
         initialAnimationDelayNanoseconds: UInt64 = 0) {
        self.currentPoints = currentPoints
        self.totalPoints = totalPoints
        self.innerGradientColors = innerGradientColors
        self.initialAnimationDelayNanoseconds = initialAnimationDelayNanoseconds
    }

    // H5 精确尺寸
    private let barWidth: CGFloat = 220
    private let barHeight: CGFloat = 14
    private let innerMaxWidth: CGFloat = 218
    private let innerHeight: CGFloat = 12

    @State private var displayRatio: CGFloat = 0

    /// 目标 ratio 硬夹到 [0, 1](对齐 H5 Math.min(100, ...))
    private var targetRatio: CGFloat {
        guard totalPoints > 0 else { return 0 }
        return min(1.0, CGFloat(currentPoints) / CGFloat(totalPoints))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: 0x332D87))
                .frame(width: barWidth, height: barHeight)
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: innerGradientColors,
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: max(0, innerMaxWidth * displayRatio), height: innerHeight)
                .padding(.leading, 1)
        }
        .frame(width: barWidth, height: barHeight, alignment: .leading)
        .task {
            if initialAnimationDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: initialAnimationDelayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.0)) {
                displayRatio = targetRatio
            }
        }
        .onChange(of: targetRatio) { newValue in
            withAnimation(.easeOut(duration: 1.0)) {
                displayRatio = newValue
            }
        }
    }
}

// MARK: - Tab1 粉红渐变(preset)

extension LiveGiftProgressBar {
    static let liveGiftGradient: [Color] = [
        Color(hex: 0xFF9438), Color(hex: 0xFF0090), Color(hex: 0xFE00DE)
    ]
    static let activeTycoonGradient: [Color] = [
        Color(hex: 0xFFE08A), Color(hex: 0xFFA42E), Color(hex: 0xFF7A00)
    ]
}

// MARK: - Preview

#if DEBUG
struct LiveGiftProgressBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            LiveGiftProgressBar(currentPoints: 0, totalPoints: 5000,
                                innerGradientColors: LiveGiftProgressBar.liveGiftGradient)
            LiveGiftProgressBar(currentPoints: 1200, totalPoints: 5000,
                                innerGradientColors: LiveGiftProgressBar.liveGiftGradient)
            LiveGiftProgressBar(currentPoints: 5000, totalPoints: 5000,
                                innerGradientColors: LiveGiftProgressBar.liveGiftGradient)
            LiveGiftProgressBar(currentPoints: 30000, totalPoints: 100000,
                                innerGradientColors: LiveGiftProgressBar.activeTycoonGradient)
        }
        .padding()
        .background(Color(hex: 0x1D0E4C))
        .previewLayout(.sizeThatFits)
    }
}
#endif

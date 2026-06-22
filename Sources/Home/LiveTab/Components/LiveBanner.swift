import SwiftUI

/// 圣诞活动 banner：左侧标题+日期，右侧圣诞老人雪橇插画（无素材时用占位渐变 + emoji 兜底）。
struct LiveBanner: View {
    let data: LiveBannerData

    var body: some View {
        HStack(spacing: 0) {
            leftCopy
            Spacer(minLength: 8)
            illustration
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.Metric.liveBannerHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.liveBanner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.Palette.liveBannerFill, Color(hex: 0x3B1452)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.liveBanner, style: .continuous)
                .strokeBorder(Theme.Palette.liveBannerBorder.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(data.title) \(data.period)")
    }

    private var leftCopy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(data.title)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(hex: 0xFFE56E), Color(hex: 0xFFFFFF)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(data.period)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
    }

    /// 右侧插画占位：渐变圆 + 圣诞 emoji。
    /// 后续接入真实活动 banner 图后替换为 Image。
    private var illustration: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: 0xFFB347, opacity: 0.85),
                            Color(hex: 0xC026D3, opacity: 0.4),
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 60
                    )
                )
                .frame(width: 90, height: 90)
                .blur(radius: 4)
            Text("🎅")
                .font(.system(size: 48))
        }
        .frame(width: 96, height: 76)
        .accessibilityHidden(true)
    }
}

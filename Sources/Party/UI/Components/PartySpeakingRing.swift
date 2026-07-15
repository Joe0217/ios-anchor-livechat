import SwiftUI

/// Party 房间"正在说话"视觉反馈（对齐 H5 `PlayVolume` 序列帧 + `voice-print-frame` 简化版）。
///
/// H5 蓝本：
/// - 语音位（audio-wrap.vue）：PlayVolume 48 帧图片切换（50ms/帧，2.4s 一循环）
/// - 视频位（main-wrap.vue）：VoicePrintFrame SVGA 特效（需 anchorTaskRewardExt.vfxUrl 佩戴）
///
/// iOS 主播端简化：不引 SVGA，用 SwiftUI 原生 `.repeatForever` scale/opacity 呼吸。
/// isSpeaking=false 时 opacity 0（不显示但保留视图，避免 mount/unmount 重启动画抖动）。

/// 小语音位专用：头像外圈 2 环交错 pulse（scale 1.0→1.15 + opacity 0.6→0）。
/// 与 `partySeatRing` 同心；不改变布局尺寸（用 overlay 挂）。
struct PartySmallSeatSpeakingRing: View {
    let isSpeaking: Bool
    let diameter: CGFloat

    @State private var animate: Bool = false

    var body: some View {
        ZStack {
            // 外环 · 相位 0
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: diameter, height: diameter)
                .scaleEffect(animate ? 1.15 : 1.0)
                .opacity(animate ? 0.0 : 0.6)
            // 内环 · 相位 0.2s 延迟（交错扩散效果）
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
                .frame(width: diameter, height: diameter)
                .scaleEffect(animate ? 1.15 : 1.0)
                .opacity(animate ? 0.0 : 0.6)
                .animation(
                    .easeOut(duration: 0.8)
                        .repeatForever(autoreverses: false)
                        .delay(0.2),
                    value: animate
                )
        }
        .opacity(isSpeaking ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isSpeaking)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { animate = true }
    }
}

/// 大视频位专用：容器外框 stroke + shadow 呼吸（scale 1.0→1.03 + opacity 0.4→1.0）。
/// 与视频容器同尺寸；用 overlay 挂在 stackContent 外层。
struct PartyBigSeatSpeakingBorder: View {
    let isSpeaking: Bool
    let cornerRadius: CGFloat

    @State private var animate: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(Color.white.opacity(0.95), lineWidth: 2)
            .shadow(color: Color.white.opacity(0.6), radius: 8)
            .scaleEffect(animate ? 1.03 : 1.0)
            .opacity(animate ? 1.0 : 0.4)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: animate
            )
            .opacity(isSpeaking ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: isSpeaking)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { animate = true }
    }
}

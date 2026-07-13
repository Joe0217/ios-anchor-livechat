import SwiftUI

/// 语音消息气泡（H-2 spec §1 表 1.8，对齐 H5 `msgItem.vue:262-268`）。
///
/// **视觉**：宽 80，喇叭 icon 18 白色 + dur 秒数。播放中显示波纹动画。
/// tap 触发播放（AVAudioPlayer 接线延到 step 2）。
struct AudioBubbleView: View {
    let dur: Int
    let isOutgoing: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if isOutgoing { Spacer(minLength: 0); durationLabel; iconView }
                else { iconView; durationLabel; Spacer(minLength: 0) }
            }
            .padding(.horizontal, 10)
            .frame(width: ChatConstants.audioBubbleWidth + CGFloat(dur.clamped(1, 60)) * 2, height: 36)
            .background(isOutgoing ? ChatPalette.myBubbleBackground : ChatPalette.peerBubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // S-7:a11y VoiceOver 念"播放/暂停 N 秒语音"而非"按钮"
        .accessibilityLabel(isPlaying ? L10n.chatA11yAudioPause(sec: dur) : L10n.chatA11yAudioPlay(sec: dur))
    }

    private var iconView: some View {
        // iOS 17+ 用 symbolEffect 波纹动画；iOS 16 fallback 用切换 icon
        Group {
            if #available(iOS 17.0, *) {
                Image(systemName: "speaker.wave.2.fill")
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            } else {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.wave.1.fill")
            }
        }
        .font(.system(size: 18))
        .foregroundStyle(.white)
    }

    private var durationLabel: some View {
        Text("\(dur)\"")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .monospacedDigit()
    }
}

private extension Int {
    func clamped(_ min: Int, _ max: Int) -> Int {
        Swift.min(Swift.max(self, min), max)
    }
}

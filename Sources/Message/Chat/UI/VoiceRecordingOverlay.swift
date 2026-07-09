import SwiftUI

/// 录音浮层（H-2 spec §4.3，对齐 H5 `recording.vue`）。
///
/// **状态**：`.recording(seconds)` 或 `.willCancel`；`nil` 不显示。
/// **视觉**：中心固定 fixed 卡片，rgba(119,70,210,0.5) 半透明紫，圆角 8。
enum VoiceRecordingState: Equatable {
    case recording(seconds: Int)
    case willCancel(seconds: Int)
}

struct VoiceRecordingOverlay: View {
    let state: VoiceRecordingState?

    var body: some View {
        if let state {
            ZStack {
                // 全屏 dim 略淡（保留可视但突出中心）
                Color.black.opacity(0.3).ignoresSafeArea()

                VStack(spacing: 12) {
                    icon(for: state)
                    Text(secondsDisplay(state))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(.white)
                    hintCapsule(state)
                }
                .padding(24)
                .frame(minWidth: 200, minHeight: 140)
                .background(Color(red: 119/255, green: 70/255, blue: 210/255, opacity: 0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private func icon(for state: VoiceRecordingState) -> some View {
        switch state {
        case .recording:
            micIcon(pulsing: true)
        case .willCancel:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
        }
    }

    private func secondsDisplay(_ state: VoiceRecordingState) -> String {
        switch state {
        case .recording(let s), .willCancel(let s):
            return "\(s)s"
        }
    }

    /// iOS 17+ 用 symbolEffect .pulse；iOS 16 fallback 用 opacity 动画
    @ViewBuilder
    private func micIcon(pulsing: Bool) -> some View {
        if #available(iOS 17.0, *) {
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
        } else {
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .opacity(pulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulsing)
        }
    }

    @ViewBuilder
    private func hintCapsule(_ state: VoiceRecordingState) -> some View {
        let text: String = {
            switch state {
            case .recording: return "Slide up to cancel"
            case .willCancel: return "Release to cancel"
            }
        }()
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(ChatPalette.primaryLightGradient, in: Capsule())
    }
}

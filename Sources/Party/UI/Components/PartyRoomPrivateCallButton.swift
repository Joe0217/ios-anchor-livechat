import SwiftUI

/// 派对房私 call 开关卡片（对齐设计稿 · F-spec §5.3 v4）。
///
/// **视觉**（对齐 `/Users/joe/Downloads/（主）私密通话开关-开启.png`）：
/// - **半透明黑色 rounded 卡片** 承载所有内容
/// - 顶部："Pavate Call" 粉色标题
/// - 开启态：礼物 icon（tap 可重新选礼物）+ 蓝钻 asset + 价格
/// - 底部：capsule toggle（粉色渐变/灰色）+ 白色 knob（含 video icon）
///
/// **交互分层**：
/// - tap **礼物 icon**：只在开启态生效 → 触发 `onTapGift`（重新弹 gift panel 选礼物，不影响开关状态）
/// - tap **capsule toggle**：触发 `onToggle(!isOn)` 开/关切换
struct PartyRoomPrivateCallButton: View {
    let isOn: Bool
    /// 有 gift meta cache 就显示 preview（不依赖 isOn；让关闭态也能看到"上次记忆的礼物"）
    var selectedGiftIcon: String? = nil
    var selectedGiftPrice: Int? = nil
    /// v5-需求 2：切换 API 在飞时显示 spinner + 屏蔽 tap（避免重复点击）
    var isLoading: Bool = false
    let onToggle: (Bool) -> Void
    /// tap 礼物 icon → 触发（重新）选礼物 · 弹 gift panel
    var onTapGift: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            // 顶部 "Pavate Call" 标题
            Text(L10n.Party.toolPrivateCall)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: 0xFD79C1))

            // 礼物 preview + 蓝钻价格 —— 只要有 gift meta 缓存就显示（不依赖 isOn，
            // 让用户在开关关闭态也能看到"上次记忆的礼物"，进房后立即预告"如果开启会用哪个礼物"）
            if let url = selectedGiftIcon, !url.isEmpty {
                CachedAsyncImage(url: URL(string: url)) {
                    Color.white.opacity(0.05)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .onTapGesture {
                    onTapGift()
                }
            }
            if let price = selectedGiftPrice, price > 0 {
                HStack(spacing: 3) {
                    Image("partyGems")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                    Text("\(price)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            // 底部 capsule toggle
            capsuleToggle
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.Party.toolPrivateCall))
        .accessibilityValue(Text(isOn ? "on" : "off"))
    }

    private var capsuleToggle: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(capsuleFill)
                .frame(width: 44, height: 24)
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                if isLoading {
                    // v5-需求 2：切换 API 在飞时用 spinner 替代 icon（对齐视觉体量 20pt）
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.55)
                        .tint(isOn ? Color(hex: 0xFD79C1) : Color(hex: 0x898989))
                } else {
                    Image(systemName: isOn ? "video.fill" : "video.slash.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isOn ? Color(hex: 0xFD79C1) : Color(hex: 0x898989))
                }
            }
            .padding(2)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture {
            // API 在飞时屏蔽 tap 防重复点击
            guard !isLoading else { return }
            onToggle(!isOn)
        }
        .allowsHitTesting(!isLoading)
    }

    private var capsuleFill: AnyShapeStyle {
        if isOn {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: 0xFF6EC7), Color(hex: 0xFD79C1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            return AnyShapeStyle(Color(hex: 0x898989))
        }
    }
}

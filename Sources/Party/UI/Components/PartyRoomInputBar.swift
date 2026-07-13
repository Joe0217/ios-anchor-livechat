import SwiftUI

/// Party 房间底部输入 + 工具栏（对齐设计稿 2026-07-11）。
///
/// 结构：输入框（Say hello...）+ 表情 / 喇叭 / 麦 / 游戏 / 礼物 5 个圆按钮。
struct PartyRoomInputBar: View {
    @Binding var text: String
    let micOn: Bool
    let speakerOn: Bool
    let onSubmit: () -> Void
    let onEmojiTap: () -> Void
    let onSpeakerTap: () -> Void
    let onMicTap: () -> Void
    let onGameTap: () -> Void
    let onGiftTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metric.partyRoomToolBtnGap) {
            inputField
            emojiButton
            speakerButton
            micButton
            gameButton
            giftButton
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
        .padding(.vertical, 8)
    }

    // MARK: - 输入框

    private var inputField: some View {
        HStack(spacing: 6) {
            TextField("", text: $text, prompt:
                Text(L10n.PartyRoom.inputPlaceholder)
                    .foregroundColor(Theme.Palette.partyRoomInputPlaceholder)
            )
            .foregroundColor(.white)
            .font(Theme.Typography.partyRoomInputPlaceholder)
            .textFieldStyle(.plain)
            .submitLabel(.send)
            .onSubmit(onSubmit)
        }
        .padding(.horizontal, Theme.Metric.partyRoomInputHPadding)
        .frame(height: Theme.Metric.partyRoomInputHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.partyRoomInput, style: .continuous)
                .fill(Theme.Palette.partyRoomInputFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.partyRoomInput, style: .continuous)
                        .stroke(Theme.Palette.partyRoomInputBorder, lineWidth: 0.5)
                )
        )
    }

    // MARK: - 工具按钮

    private var emojiButton: some View {
        toolBtn(asset: "partyIconEmoji",
                a11y: L10n.PartyRoom.a11yEmoji,
                tinted: true,
                action: onEmojiTap)
    }

    private var speakerButton: some View {
        toolBtn(asset: "partyIconSpeaker",
                a11y: speakerOn ? L10n.PartyRoom.a11ySpeakerOn : L10n.PartyRoom.a11ySpeakerOff,
                tinted: true,
                action: onSpeakerTap)
    }

    private var micButton: some View {
        toolBtn(asset: micOn ? "partyIconMicOn" : "partyIconMicMuted",
                a11y: micOn ? L10n.PartyRoom.a11yMicOn : L10n.PartyRoom.a11yMicOff,
                tinted: false,
                action: onMicTap)
    }

    private var gameButton: some View {
        toolBtn(asset: "partyIconGame",
                a11y: L10n.PartyRoom.a11yGame,
                tinted: false,
                action: onGameTap)
    }

    private var giftButton: some View {
        toolBtn(asset: "partyIconGift",
                a11y: L10n.PartyRoom.a11yGift,
                tinted: false,
                action: onGiftTap)
    }

    /// 通用工具按钮
    /// - tinted: 白线单色图标走 template，3D 彩色图标（游戏/礼物）走 original
    /// - v2：5 图标统一背景 `white 5%` 圆底，与视频位空位设计语言一致
    private func toolBtn(asset: String,
                         a11y: String,
                         tinted: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            iconImage(asset: asset, tinted: tinted)
                .frame(width: Theme.Metric.partyRoomToolBtnSize,
                       height: Theme.Metric.partyRoomToolBtnSize)
                .background(Circle().fill(Color.white.opacity(0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    @ViewBuilder
    private func iconImage(asset: String, tinted: Bool) -> some View {
        if tinted {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(.white)
                .scaledToFit()
                .padding(4)
        } else {
            Image(asset)
                .resizable()
                .scaledToFit()
                .padding(2)
        }
    }
}

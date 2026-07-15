import SwiftUI

/// Party 房间底部输入 + 工具栏（v16.10 · 完全对齐直播间 `LiveRoomInputRow` 交互）。
///
/// **v16.10 关键**：完全对齐 [`LiveRoomView.swift:395`](../../Live/LiveRoomView.swift#L395) pattern：
/// - **内嵌 TextField**（不用 sheet）：`.focused(focus)` 桥接父 view `@FocusState`
/// - **focused 时右侧按钮全部隐藏**，TextField 占满宽度（`if !focus.wrappedValue`）
/// - `.animation(.easeInOut(duration: 0.2), value: focus.wrappedValue)` 平滑收合
/// - 键盘弹起由 SwiftUI 默认避让处理（背景层已用 UIScreen.main.bounds 锁定不变形）
///
/// 按钮顺序（未 focused 时全显）：输入框 · emoji · message · mic · game · toolMenu · gift
struct PartyRoomInputBar: View {
    @Binding var text: String
    let micOn: Bool
    /// 自己是否已上麦（emoji + mic 按钮显隐门槛：H5 `inPartyRole > -1`）
    let isOnSeat: Bool
    /// 是否显示游戏按钮（H5 v-if=hasGameCenter；主播端默认 false）
    let showGameButton: Bool
    /// 消息按钮未读徽章数（对齐 H5 useUnreadMessageCount + van-badge，>99 显 99+）
    let unreadCount: Int
    /// v16.10：父 view FocusState 桥（focused 时收起右侧按钮，让 TextField 占满宽度）
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onEmojiTap: () -> Void
    let onMessageTap: () -> Void
    let onMicTap: () -> Void
    let onGameTap: () -> Void
    let onToolMenuTap: () -> Void
    let onGiftTap: () -> Void

    var body: some View {
        HStack(spacing: Theme.Metric.partyRoomToolBtnGap) {
            inputField
            // v16.10：focused 时右侧图标全隐藏，TextField 占满（对齐 LiveRoomView L423 pattern）
            if !focus.wrappedValue {
                emojiButton
                    .opacity(isOnSeat ? 1 : 0)
                    .allowsHitTesting(isOnSeat)
                    .accessibilityHidden(!isOnSeat)
                messageButton
                micButton
                    .opacity(isOnSeat ? 1 : 0)
                    .allowsHitTesting(isOnSeat)
                    .accessibilityHidden(!isOnSeat)
                if showGameButton { gameButton }
                toolMenuButton
                giftButton
            }
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: focus.wrappedValue)
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
            .focused(focus)
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

    /// 消息（含未读徽章；对齐 H5 useUnreadMessageCount + van-badge）
    private var messageButton: some View {
        systemToolBtn(symbol: "envelope.fill",
                      a11y: L10n.PartyRoom.a11yMessage,
                      action: onMessageTap)
            .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }
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

    /// 更多工具菜单（对齐 H5 party-tool-menu.vue：PK / Lucky Number / Room Mute 汇总入口）
    private var toolMenuButton: some View {
        systemToolBtn(symbol: "ellipsis.circle.fill",
                      a11y: L10n.PartyRoom.a11yToolMenu,
                      action: onToolMenuTap)
    }

    private var giftButton: some View {
        toolBtn(asset: "partyIconGift",
                a11y: L10n.PartyRoom.a11yGift,
                tinted: false,
                action: onGiftTap)
    }

    /// 通用工具按钮（专用 asset 版）
    /// - tinted: 白线单色图标走 template，3D 彩色图标（游戏/礼物）走 original
    /// - 图标统一背景 `white 5%` 圆底
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

    /// SF Symbol 版工具按钮（占位；message / toolMenu 无 3D asset 时使用）
    private func systemToolBtn(symbol: String,
                               a11y: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
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

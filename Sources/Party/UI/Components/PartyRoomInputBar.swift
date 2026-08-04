import SwiftUI

/// Party 房间底部输入 + 工具栏（v16.10 · 完全对齐直播间 `LiveRoomInputRow` 交互）。
///
/// **v16.10 关键**：完全对齐 [`LiveRoomView.swift:395`](../../Live/LiveRoomView.swift#L395) pattern：
/// - **内嵌 TextField**（不用 sheet）：`.focused(focus)` 桥接父 view `@FocusState`
/// - **focused 时右侧按钮全部隐藏**，TextField 占满宽度（`if !focus.wrappedValue`）
/// - `.animation(.easeInOut(duration: 0.2), value: focus.wrappedValue)` 平滑收合
/// - 键盘弹起由 SwiftUI 默认避让处理（背景层已用 UIScreen.main.bounds 锁定不变形）
///
/// 按钮顺序（未 focused 时全显）：输入框 · [micApplication] · emoji · message · mic · game · toolMenu · gift
/// - micApplication：房主/房管 + 排麦开关开 时显示（对齐安卓 flMicApplication 输入框上方快捷入口）
struct PartyRoomInputBar: View {
    @Binding var text: String
    let micOn: Bool
    /// 自己是否已上麦（emoji + mic 按钮显隐门槛：H5 `inPartyRole > -1`）
    let isOnSeat: Bool
    /// 是否显示游戏按钮（H5 v-if=hasGameCenter；主播端默认 false）
    let showGameButton: Bool
    /// 107 Party-only 账号不显示送礼入口。
    let showGiftButton: Bool
    /// Party-only 账号不进入 P2P 会话中心。
    let showMessageButton: Bool
    /// 消息按钮未读徽章数（对齐 H5 useUnreadMessageCount + van-badge，>99 显 99+）
    let unreadCount: Int
    /// 对齐安卓 §1 checkMicApplicationVisible：`onSeatApplySwitch && (owner||admin||平台管理员)` 才显示
    let showMicApplicationButton: Bool
    /// 排麦申请队列红角标（对齐安卓 tvMicApplicationNum；`0` 不显示 badge）
    let micApplicationBadge: Int
    /// H5 房内底栏的一键发送词条（主播端取 audienceType=2）。
    let quickPhrases: [PartyQuickPhrase]
    let showsQuickPhrases: Bool
    /// v16.10：父 view FocusState 桥（focused 时收起右侧按钮，让 TextField 占满宽度）
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onEmojiTap: () -> Void
    let onMessageTap: () -> Void
    let onMicTap: () -> Void
    let onGameTap: () -> Void
    let onToolMenuTap: () -> Void
    let onGiftTap: () -> Void
    /// 排麦快捷入口 tap（房主/房管直达 Mic Application sheet，绕过 Tools sheet 二层）
    let onMicApplicationTap: () -> Void
    let onQuickPhraseTap: (PartyQuickPhrase) -> Void
    let onQuickPhrasesClose: () -> Void
    let onQuickPhraseSlide: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showsQuickPhrases, !quickPhrases.isEmpty {
                quickPhraseBar
            }

            toolbar
        }
        .animation(.easeInOut(duration: 0.2), value: focus.wrappedValue)
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Metric.partyRoomToolBtnGap) {
            inputField
            // v16.10：focused 时右侧图标全隐藏，TextField 占满（对齐 LiveRoomView L423 pattern）
            if !focus.wrappedValue {
                // 对齐安卓 flMicApplication：输入框旁快捷入口，房主/房管 + 排麦开关开时可见 + queueSeatNum badge
                if showMicApplicationButton {
                    micApplicationButton
                }
                // H5 `footer-wrap.vue` 仅在 `inPartyRole > -1`（本人在麦）时展示表情入口。
                if isOnSeat {
                    emojiButton
                }
                if showMessageButton { messageButton }
                if isOnSeat {
                    micButton
                }
                if showGameButton { gameButton }
                toolMenuButton
                if showGiftButton { giftButton }
            }
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
        .padding(.vertical, 8)
    }

    /// H5 `quick-phrase-bar.vue`：横向滚动词条 + 独立关闭按钮，固定 42pt 高并贴在底栏上沿。
    private var quickPhraseBar: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .trailing) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(quickPhrases) { phrase in
                            Button {
                                onQuickPhraseTap(phrase)
                            } label: {
                                Text(phrase.content)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.72))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: 180)
                                    .background(
                                        Capsule().fill(Color(hex: 0x241C3A))
                                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(phrase.content)
                        }
                    }
                    .padding(.leading, 5)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            onQuickPhraseSlide(value.translation.width < 0 ? "left" : "right")
                        }
                )
            }
            .frame(maxWidth: .infinity)

            Button(action: onQuickPhrasesClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Party.cancel)
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .frame(height: 42)
        .background(
            // 关闭按钮同属快捷消息栏，整行使用同一层 20% 透明底色。
            Color(hex: 0x14112B, opacity: 0.2)
        )
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

    /// 排麦申请快捷入口（对齐安卓 flMicApplication：输入框旁常驻按钮 + queueSeatNum 红角标）
    /// 房主/房管 + 排麦开关开 时可见；tap 直达 Mic Application sheet（绕过 Tools sheet 二层）
    private var micApplicationButton: some View {
        systemToolBtn(symbol: "hand.raised.fill",
                      a11y: L10n.Party.toolMicApplication,
                      action: onMicApplicationTap)
            .overlay(alignment: .topTrailing) {
                if micApplicationBadge > 0 {
                    Text(micApplicationBadge > 99 ? "99+" : "\(micApplicationBadge)")
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
            CDNAssetImage(asset)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(.white)
                .scaledToFit()
                .padding(4)
        } else {
            CDNAssetImage(asset)
                .resizable()
                .scaledToFit()
                .padding(2)
        }
    }
}

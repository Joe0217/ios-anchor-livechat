import SwiftUI

/// H-3 私聊页底部操作栏（spec §4.2 / §1.5.1-1.5.13）。
///
/// **对齐设计稿**（`消息UI/私聊页切图位置.png` §底部 4 icon）：
/// - **regular** + canCall：语音 / 视频 / 照片 / 私密 —— 4 按钮
/// - **regular** + !canCall：视频通话按钮隐藏
/// - **customer**（系统通知 / 客服）：**仅普通相册**（语音/视频/私密全隐藏）
///
/// **语音按钮**在任何 inputMode 下都显示，tap 时 toggle（text ↔ voice）——
/// 这样移除 ChatInputBar 左侧的 modeSwitchButton 后，用户仍有唯一入口切回 text 模式。
///
/// **按钮尺寸**：40x40（对齐设计稿彩色 icon）；spacing 20；水平内边距 16
struct BottomActionBar: View {
    let chatType: ChatType
    let canCall: Bool
    var canUsePrivateMedia: Bool = true
    let inputMode: ChatInputBar.InputMode

    let onToggleVoice: () -> Void
    let onTapCall: () -> Void
    let onOpenRegularAlbum: () -> Void
    let onOpenPrivateAlbum: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            switch chatType {
            case .regular:
                // 语音按钮：voice mode 下高亮/常态区分（视觉反馈"当前处于语音模式"）
                OperateButton(imageName: "ChatBottomVoice",
                              accessibilityLabel: inputMode == .voice ? "Switch to keyboard" : "Voice",
                              highlighted: inputMode == .voice,
                              action: onToggleVoice)
                if canCall {
                    OperateButton(imageName: "ChatBottomVideo",
                                  accessibilityLabel: "Video Call",
                                  action: onTapCall)
                }
                OperateButton(imageName: "ChatBottomPhoto",
                              accessibilityLabel: "Album",
                              action: onOpenRegularAlbum)
                if canUsePrivateMedia {
                    OperateButton(imageName: "ChatBottomPrivate",
                                  accessibilityLabel: "Private Album",
                                  action: onOpenPrivateAlbum)
                }
            case .customer:
                // 客服会话仅相册按钮（走系统 PhotosPicker 读手机相册,由 caller 挂 PhotosPicker）
                OperateButton(imageName: "ChatBottomPhoto",
                              accessibilityLabel: "Album",
                              action: onOpenRegularAlbum)
            case .system:
                // 系统通知只读：整个底部操作栏隐藏（由 ChatDetailView 层不渲染 BottomActionBar 达成）
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(ChatPalette.pageBackground)
    }
}

/// 40x40 彩色 icon 操作按钮（对齐设计稿 `消息列表_slices/{语音|视频|照片|私密}.png`）。
///
/// **rule swiftui-button-plain-hitarea**：`buttonStyle(.plain)` + 组合容器 label 必须
/// `.contentShape(Rectangle())` 保热区覆盖 40x40 全区。
private struct OperateButton: View {
    let imageName: String
    let accessibilityLabel: String
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .opacity(highlighted ? 0.6 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

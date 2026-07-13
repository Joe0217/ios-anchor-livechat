import SwiftUI

/// 输入栏（H-3 spec §4.2 v3 两行布局的上行 input-area，对齐 H5 `chat/index.vue:1022-1043`）。
///
/// **布局**（HStack）：
/// - 中：文字输入框（h34 圆角 20 背景 #2B213E 边框 #492E7C）或"按住说话"按钮
/// - 右：send 按钮（77x34 主渐变；仅 .text 模式）
///
/// **注意**：
/// - H-3 已移除 `+` 号相册按钮 —— 相册入口在下行 BottomActionBar 的 regularAlbum/privateAlbum 独立按钮。
/// - H-3 v4（2026-07-08）已移除左侧语音/键盘切换按钮 —— 模式切换责任下沉到 BottomActionBar 语音按钮（tap toggle）。
///
/// **模式**：`.text` 显示文字输入框 + send；`.voice` 显示"按住说话"按钮
struct ChatInputBar: View {
    @Binding var text: String
    /// 当前输入模式
    @Binding var mode: InputMode
    /// 用户 tap send（仅 .text 模式）
    let onSend: () -> Void
    /// 语音按钮按下 / 松开 / 上滑取消 —— 交给 VoiceRecordingOverlay 处理
    let onVoicePressStart: () -> Void
    let onVoicePressEnd: (_ cancelled: Bool) -> Void

    /// 键盘焦点 binding（由 ChatDetailView 持 @FocusState 传入；这样父 view 可以 observe 键盘弹出滚底）
    var textFieldFocus: FocusState<Bool>.Binding

    enum InputMode: Equatable { case text, voice }

    var body: some View {
        HStack(spacing: 10) {
            centerControl
            trailingButtons
        }
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(ChatPalette.pageBackground)
        // mode → voice 时收键盘；→ text 时不主动弹（让用户 tap 输入框才弹，避免抢焦）
        .onChange(of: mode) { newMode in
            if newMode == .voice { textFieldFocus.wrappedValue = false }
        }
    }

    @ViewBuilder
    private var centerControl: some View {
        switch mode {
        case .text:
            textField
        case .voice:
            voicePressButton
        }
    }

    private var textField: some View {
        TextField("", text: $text, prompt: Text(L10n.chatInputTypeMessage).foregroundColor(.white.opacity(0.4)))
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(ChatPalette.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ChatPalette.inputBorder, lineWidth: 1)
            }
            .focused(textFieldFocus)
            .submitLabel(.send)
            .onSubmit(onSend)
            // 500 字符上限对齐 H5 `van-field maxlength="500"`——超长时静默截断,不弹提示(H5 同款)
            .onChange(of: text) { newValue in
                if newValue.count > 500 {
                    text = String(newValue.prefix(500))
                }
            }
    }

    /// 语音"按住说话"按钮 —— 用 DragGesture minimumDistance:0 实现按住 + 上滑取消
    private var voicePressButton: some View {
        Text(L10n.chatInputHoldToTalk)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(ChatPalette.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
            .gesture(voicePressGesture)
    }

    private var voicePressGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // 首次按下（translation 全 0）触发 onPressStart
                if value.translation == .zero {
                    onVoicePressStart()
                }
                // TODO step 2: 视觉反馈上滑取消阈值（>60pt 向上表示 cancel）
            }
            .onEnded { value in
                let cancelled = value.translation.height < -60
                onVoicePressEnd(cancelled)
            }
    }

    /// H-3：`+` 号已移除；相册入口下沉到 BottomActionBar 的 regularAlbum / privateAlbum 独立按钮
    @ViewBuilder
    private var trailingButtons: some View {
        if mode == .text {
            sendButton
        }
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Text(L10n.chatInputSend)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 77, height: 34)
                .background(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? AnyShapeStyle(Color.gray.opacity(0.4))
                            : AnyShapeStyle(ChatPalette.primaryGradient))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

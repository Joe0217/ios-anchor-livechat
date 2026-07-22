import SwiftUI

/// 派对房加锁密码输入 sheet（E spec §3.4）—— 房主未锁态从 Room Tools tap Lock Room 弹起。
///
/// 4 位纯数字密码（对齐 H5 `van-password-input length=4`）；成功后本 sheet 自动 dismiss，
/// 失败通过内联错态文案提示 + 保留输入让用户可重试（spec §4 R2）。
///
/// **解锁不走本 sheet**：spec §3.4 已锁态 tap Lock Room 由父层直接调
/// `PartyStore.unlockRoom()` 无二次确认（对齐 H5）。本 sheet 内部同时兜底一个"当前状态"
/// label 兼容显示上下文，即便被上层误在已锁态弹出也不会展示错乱的可点按钮。
struct PartyLockRoomSheet: View {
    @ObservedObject var store: PartyStore

    // sheet 自 dismiss（成功后收起 + 系统 back gesture）
    @Environment(\.dismiss) private var dismiss

    // 4 位数字密码明文（WHY：SecureField 内部密文渲染 + 提交后立即 clear，不留状态；不打日志）
    @State private var passwordInput: String = ""
    @FocusState private var focused: Bool
    // 错态文字仅内联展示，不复用 store.lastError toast 通道（sheet 内 UX 更近场景）
    @State private var errorMsg: String? = nil
    // sheet-局部 in-flight（store.isBusyLockRoom private 不可读，此处独立管 UI 态；
    // store 内 guard 已幂等，两侧 flag 各自负责各自视觉）
    @State private var isSubmitting = false

    // 密码长度（spec §1：4 位纯数字）
    private let requiredLength = 4

    private var isLocked: Bool { store.roomInfo?.lockFlag == 1 }
    private var canSubmit: Bool {
        !isSubmitting
            && passwordInput.count == requiredLength
            && passwordInput.allSatisfy(\.isNumber)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                Text(L10n.Party.lockRoomSheetTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 20)

                // 当前状态：sheet 打开时房间的加锁态；已锁复用 lockRoomLockSuccess("Room locked")、
                // 未锁复用 lockRoomUnlockSuccess("Room unlocked") —— 两个字符串本就是状态文案的自然语言
                Text(isLocked ? L10n.Party.lockRoomLockSuccess : L10n.Party.lockRoomUnlockSuccess)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))

                Text(L10n.Party.lockRoomSheetDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                SecureField(L10n.Party.lockRoomPasswordPlaceholder, text: $passwordInput)
                    .keyboardType(.decimalPad)
                    // spec §4 R3 security：新密码用 .newPassword（非 .oneTimeCode 避免 SMS
                    // OTP QuickType autofill 把无关验证码填进密码栏泄漏到后端 log）
                    .textContentType(.newPassword)
                    .focused($focused)
                    .foregroundColor(.white)
                    .tint(Theme.Palette.partyCreateChevron)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
                    .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
                    .padding(.horizontal, 40)
                    // WHY: 粘贴/输入即过滤，只留数字并截到 4 位；杜绝非数字字符污染 payload
                    .onChange(of: passwordInput) { newValue in
                        let digitsOnly = newValue.filter(\.isNumber)
                        let trimmed = String(digitsOnly.prefix(requiredLength))
                        if trimmed != newValue { passwordInput = trimmed }
                        if !trimmed.isEmpty { errorMsg = nil }
                    }

                if let msg = errorMsg, !msg.isEmpty {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xFF6B7A))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 0)

                Button(action: submit) {
                    HStack(spacing: 6) {
                        if isSubmitting {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        }
                        Text(L10n.Party.lockRoomLockAction)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .opacity(canSubmit ? 1 : 0.5)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.height(320)])
        // WHY: sheet 弹起自动聚焦密码框，省一次 tap
        .task { focused = true }
    }

    // MARK: - Action

    // WHY: 密码明文不落日志（rule: 不要日志明文密码）；store.lockRoom 内已幂等 + 乐观回写；
    // 用 lastError-epoch 比较判定成功/失败（不能靠 lockFlag == 1 stale-read，因为 sheet 打开时
    // lockFlag 可能已经 == 1，见 verify P0 #2）。
    private func submit() {
        guard canSubmit else { return }
        errorMsg = nil
        isSubmitting = true
        let pwd = passwordInput
        let errorBefore = store.lastError

        Task { @MainActor in
            await store.lockRoom(password: pwd)
            isSubmitting = false

            // 成功判定：store.lastError 未被 store.lockRoom 内 catch 覆盖为新错误
            let errorAfter = store.lastError
            let apiFailed = (errorAfter != nil) && (errorAfter?.errorDescription != errorBefore?.errorDescription)

            if apiFailed {
                // 消费 store.lastError 具体错误消息；若无 message 则 fallback 通用文案
                let concrete = errorAfter?.errorDescription ?? ""
                errorMsg = concrete.isEmpty ? L10n.Party.lockRoomOperationFailed : concrete
            } else {
                // 成功：清 input + dismiss（不留密码在内存）
                passwordInput = ""
                dismiss()
            }
        }
    }
}

/// 密码 Party 房进入页。与 H5 `room-password.vue` 一致，只接受 4 位数字，并在密码输入完成后自动校验。
/// 校验失败时保持在当前 sheet，绝不创建 PartyRoomView 路由。
struct PartyEnterPasswordSheet: View {
    let roomId: String
    @ObservedObject var store: PartyStore
    let onVerified: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passwordInput = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var isPasswordFocused: Bool

    private let requiredLength = 4

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            Text(L10n.Party.passwordAlertTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

            Text(L10n.Party.passwordAlertMessage)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            SecureField(L10n.Party.lockRoomPasswordPlaceholder, text: $passwordInput)
                .keyboardType(.numberPad)
                .focused($isPasswordFocused)
                .foregroundColor(.white)
                .tint(Theme.Palette.partyCreateChevron)
                .multilineTextAlignment(.center)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Capsule().fill(Theme.Palette.partyCreateInputFill))
                .overlay(Capsule().stroke(Theme.Palette.partyCreateInputBorder, lineWidth: 0.5))
                .padding(.horizontal, 40)
                .disabled(isSubmitting)
                .onChange(of: passwordInput) { value in
                    let sanitized = Self.sanitizedPassword(value, maxLength: requiredLength)
                    if sanitized != value {
                        passwordInput = sanitized
                        return
                    }
                    if !sanitized.isEmpty { errorMessage = nil }
                    if sanitized.count == requiredLength { submit() }
                }

            Group {
                if isSubmitting {
                    ProgressView()
                        .tint(.white)
                        .frame(height: 18)
                } else if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xFF6B7A))
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 18)
                        .padding(.horizontal, 24)
                } else {
                    Color.clear.frame(height: 18)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 22)
        .presentationDetents([.height(290)])
        .interactiveDismissDisabled(isSubmitting)
        .task { isPasswordFocused = true }
    }

    private func submit() {
        guard !isSubmitting, passwordInput.count == requiredLength else { return }
        let password = passwordInput
        errorMessage = nil
        isSubmitting = true

        Task { @MainActor in
            let error = await store.validateRoomEntryPassword(roomId: roomId, password: password)
            isSubmitting = false
            guard let error else {
                passwordInput = ""
                onVerified()
                dismiss()
                return
            }

            errorMessage = error.errorDescription
            // H5 密码校验失败后清空输入，下一次完整输入才会再次请求。
            passwordInput = ""
            isPasswordFocused = true
        }
    }

    private static func sanitizedPassword(_ value: String, maxLength: Int) -> String {
        var result = ""
        for scalar in value.unicodeScalars where (48...57).contains(scalar.value) {
            result.unicodeScalars.append(scalar)
            if result.count == maxLength { break }
        }
        return result
    }
}

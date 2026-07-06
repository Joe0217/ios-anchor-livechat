import SwiftUI

/// 心愿承诺规范弹窗（对齐 H5 `views/liveSetting/components/wishlist-rule-modal.vue`）。
///
/// 触发时机：LiveSettingsStore.startTapped 检测到"首次开播 + 有 wishlist + 有 promise + 未同意规范" → 弹窗
/// 交互：checkbox 勾选后 Agree 按钮才可点；用户 Agree → clickAgreement 接口 + UserDefaults 持久化 + 继续开播；
/// Cancel → 只关弹窗，用户下次 tap Start Live 仍会再弹（对齐 H5 wishRuleAgreed 单次持久化）
struct WishRuleModal: View {
    let onAgree: () async -> Void
    let onClose: () -> Void

    @State private var checked = false
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.wishRuleModalTitle)
                .font(.headline).foregroundStyle(.white)
                .padding(.top, 20)

            ScrollView {
                Text(L10n.wishSettingRuleDoc)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
            .frame(maxHeight: 200)

            HStack(spacing: 8) {
                Button { checked.toggle() } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(checked ? .pink : .white.opacity(0.5))
                }
                .buttonStyle(.plain)
                Text(L10n.wishRuleModalCheck)
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 16)

            Divider().background(Color.white.opacity(0.1))

            HStack(spacing: 0) {
                Button {
                    onClose()
                } label: {
                    Text(L10n.giftPickerCancel)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)

                Divider().frame(width: 1, height: 48).background(Color.white.opacity(0.1))

                Button {
                    guard checked, !isSubmitting else { return }
                    isSubmitting = true
                    Task {
                        await onAgree()
                        isSubmitting = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSubmitting { ProgressView().tint(.white).scaleEffect(0.7) }
                        Text(L10n.wishRuleModalAgree)
                            .font(.subheadline.bold())
                            .foregroundStyle(checked ? .pink : .white.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .disabled(!checked || isSubmitting)
            }
        }
        .frame(width: 300)
        .background(Color(hex: 0x1E1E2E), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.pink.opacity(0.2), lineWidth: 1))
    }
}

import SwiftUI

/// 昵称展示行 + 铅笔按钮触发编辑 sheet（I-spec §7.1）。
///
/// 审核态：铅笔按钮**保留可点击**，点击 action 内分流为 toast（**不用 `.disabled`**，
/// 对齐 rule `swiftui-button-plain-hitarea.md` 精神）。
struct NicknameEditRow: View {
    let nickname: String
    let isReviewing: Bool
    let onEdit: () -> Void
    let onReviewingTap: () -> Void

    var body: some View {
        // 垂直分层：label 单占一行，name + badge + pencil 单占一行
        // 昵称长时被压缩截断；badge / pencil `.fixedSize` 保持完整不被挤压
        // （2026-07-07 用户反馈：审核标识被昵称遮挡 → 改水平并列为垂直分层）
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.EditProfile.nicknameLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)

            HStack(spacing: 8) {
                Text(nickname.isEmpty ? L10n.EditProfile.nicknamePlaceholder : nickname)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(nickname.isEmpty ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)   // 空间不足时优先压缩 name（badge / pencil 保完整）

                Spacer(minLength: 4)

                if isReviewing {
                    InReviewBadge(style: .inline)
                        .fixedSize()
                }

                Button(action: {
                    isReviewing ? onReviewingTap() : onEdit()
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }
}

/// 昵称编辑 sheet（I-spec §7.2）。TextField + 字数计数 + Confirm；max 15 字截断。
struct NicknameEditSheet: View {
    let initial: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L10n.EditProfile.nicknamePlaceholder, text: $text)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(12)
                    .background(Theme.Palette.cardFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($focused)
                    .onChange(of: text) { newValue in
                        // 15 字截断
                        if newValue.count > EditProfileLimits.nicknameMaxLength {
                            text = String(newValue.prefix(EditProfileLimits.nicknameMaxLength))
                        }
                    }

                HStack {
                    Spacer()
                    Text(L10n.EditProfile.nicknameWordCountFormat(text.count))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                Spacer()
            }
            .padding(16)
            .navigationTitle(L10n.EditProfile.nicknameEditTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.EditProfile.cancel) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.EditProfile.confirm) {
                        onConfirm(text)
                        dismiss()
                    }
                    .disabled(text.isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                text = initial
                focused = true
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        NicknameEditRow(nickname: "Alice", isReviewing: false, onEdit: {}, onReviewingTap: {})
        NicknameEditRow(nickname: "AliceReviewing", isReviewing: true, onEdit: {}, onReviewingTap: {})
        NicknameEditRow(nickname: "", isReviewing: false, onEdit: {}, onReviewingTap: {})
    }
    .padding()
    .background(Theme.Palette.cardFill)
}

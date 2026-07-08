import SwiftUI

/// 简介编辑卡（I-spec §7.2）。
///
/// 审核态：TextEditor `.disabled` **无 toast**（H5 一致，rule 精神——不"统一化"）。
struct BioEditCard: View {
    @Binding var text: String
    let isReviewing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(minHeight: 96, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .disabled(isReviewing)
                    .onChange(of: text) { newValue in
                        if newValue.count > EditProfileLimits.signatureMaxLength {
                            text = String(newValue.prefix(EditProfileLimits.signatureMaxLength))
                        }
                    }
                if text.isEmpty {
                    Text(L10n.EditProfile.bioPlaceholder)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // 审核中徽章：Bio 容器中间覆盖（用户需求 2026-07-08 v2：移到容器中间，不再是底部 inline）
            .overlay(alignment: .center) {
                if isReviewing {
                    InReviewBadge(style: .overlay)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Text(L10n.EditProfile.bioWordCountFormat(text.count))
                    .font(.system(size: 12))
                    .foregroundStyle(isNearLimit ? .red.opacity(0.9) : Theme.Palette.textSecondary)
            }
        }
    }

    private var isNearLimit: Bool { text.count >= EditProfileLimits.signatureMaxLength }
}

#Preview {
    VStack(spacing: 16) {
        BioEditCard(text: .constant("Hello world"), isReviewing: false)
        BioEditCard(text: .constant("Under review bio"), isReviewing: true)
        BioEditCard(text: .constant(""), isReviewing: false)
    }
    .padding()
    .background(Theme.Palette.cardFill)
}

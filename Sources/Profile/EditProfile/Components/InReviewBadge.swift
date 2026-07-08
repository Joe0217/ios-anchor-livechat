import SwiftUI

/// 审核中徽章（I-spec §7.2）。
///
/// 两种样式：
/// - `.inline`：胶囊贴在字段右侧（用于昵称行）
/// - `.overlay`：居中徽章（用于头像/Bio 容器中间覆盖态；2026-07-08 v2 缩小文案与 inline 对齐）
struct InReviewBadge: View {
    enum Style {
        case inline
        case overlay
    }

    let style: Style

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "clock.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(L10n.EditProfile.badgeInReview)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, style == .overlay ? 3 : 2)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 12) {
        InReviewBadge(style: .inline)
        InReviewBadge(style: .overlay)
    }
    .padding()
    .background(Theme.Palette.screenBackground)
}

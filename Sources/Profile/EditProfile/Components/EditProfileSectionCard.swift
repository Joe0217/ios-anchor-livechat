import SwiftUI

/// 编辑页 section 通用卡片容器（I-spec §7.1）。
///
/// - title：section 标题（可含格式化 %d/max）
/// - hint：副标题提示（可选）
/// - content：section 主体（slot）
struct EditProfileSectionCard<Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder let content: () -> Content

    init(title: String, hint: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let hint {
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            content()
        }
        .padding(16)
        .background(Theme.Palette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            EditProfileSectionCard(title: "Basic Info", hint: "Improve your profile") {
                Text("Slot content")
                    .foregroundStyle(.white)
            }
            EditProfileSectionCard(title: "Photos (3/9)") {
                Rectangle().fill(.gray).frame(height: 60)
            }
        }
        .padding()
    }
    .background(Theme.Palette.screenBackground)
}

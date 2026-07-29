import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L519-522
/// 视觉：max-w249 min-h22 rounded-12 px-8 py-5 · bg-#D33901/30 暗红 · border-#FA7800/50
/// 内容：RichSegment 数组 v-html 拼接
struct RowPKNotify: View {
    let richText: [RichSegment]
    let theme: PublicChatTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(richText.enumerated()), id: \.offset) { _, seg in
                segView(seg)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 249, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 211/255, green: 57/255, blue: 1/255).opacity(0.3))   // #D33901/30
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 250/255, green: 120/255, blue: 0).opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder private func segView(_ seg: RichSegment) -> some View {
        switch seg {
        case .text(let s, let color):
            Text(s)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
        case .highlight(let s, let color):
            Text(s)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
        case .iconURL(let url, let size):
            if let u = URL(string: url) {
                CachedAsyncImage(url: u, contentMode: .fit) { Color.clear }
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}

/// H5 PK 结束后继胜负公告展示的贡献榜前三。
/// H5 使用一条带 br/font 的 pk_notification；iOS 用三行结构化视图避免 HTML 解析。
struct RowPKTopContributors: View {
    let users: [PublicChatUserTarget]
    let onTapNickname: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.publicScreenPKTopContributors)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            ForEach(Array(displayUsers.enumerated()), id: \.offset) { index, user in
                HStack(spacing: 4) {
                    Text(rankTitle(index))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    nickname(user)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 249, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 211/255, green: 57/255, blue: 1/255).opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(red: 250/255, green: 120/255, blue: 0).opacity(0.5), lineWidth: 0.5)
                )
        )
    }

    private var displayUsers: [PublicChatUserTarget] {
        (0..<3).map { index in
            guard users.indices.contains(index), !users[index].nickname.isEmpty else {
                return PublicChatUserTarget(userId: nil, nickname: "-", isSelf: false)
            }
            return users[index]
        }
    }

    @ViewBuilder
    private func nickname(_ user: PublicChatUserTarget) -> some View {
        let label = Text(user.nickname)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(red: 1.0, green: 168/255, blue: 0))
        if let userId = user.userId, !userId.isEmpty, let onTapNickname {
            Button(action: { onTapNickname(userId) }) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(user.nickname))
        } else {
            label
        }
    }

    private func rankTitle(_ index: Int) -> String {
        switch index {
        case 0: return L10n.publicScreenPKTop1
        case 1: return L10n.publicScreenPKTop2
        default: return L10n.publicScreenPKTop3
        }
    }
}

import SwiftUI

/// H5 源：`wishlist-chat-effect.vue`。
/// 仅 251 TOP1 变更进入公屏；昵称为金色且可点开资料卡，251 之外的心愿节点不写公屏。
struct RowWishlistEffect: View {
    let sender: SenderProfile?
    let onTapNickname: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let onTapNickname {
                Button(action: onTapNickname) {
                    nickname
                }
                .buttonStyle(.plain)
            } else {
                nickname
            }
            Text(L10n.wishlistTop1Prefix)
                .foregroundColor(.white)
            Text("TOP1")
                .foregroundColor(Color(hex: 0xFFD243))
                .fontWeight(.bold)
            Text(L10n.wishlistTop1Suffix)
                .foregroundColor(.white)
        }
        .font(.system(size: 12))
        .lineLimit(2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: 268, alignment: .leading)
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }

    private var nickname: some View {
        Text(sender?.nickname ?? "")
            .fontWeight(.bold)
            .foregroundColor(Color(hex: 0xFFD243))
    }
}

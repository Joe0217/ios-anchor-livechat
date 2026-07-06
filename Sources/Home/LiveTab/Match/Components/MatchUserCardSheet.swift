import SwiftUI

/// L 里程碑 Match tab：用户卡片 sheet（点击匹配用户列表小头像后弹出）。
///
/// 对齐 H5 `home/match.vue` `<userCard>`；MVP 阶段仅展示头像 + 昵称 + 年龄/性别 + 视频价 + 关闭按钮。
/// 后续里程碑（H）可扩展"点击拨打通话"能力（走 CallStore.callOut）。
struct MatchUserCardSheet: View {
    let user: MatchUserItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            // 头像（工程公共 AvatarView + 描边）
            AvatarView(urlString: user.icon, size: 96, kind: .user)
                .overlay(
                    Circle().stroke(Theme.Palette.matchMarqueeBorderStart, lineWidth: 2)
                )
                .padding(.top, 24)

            // 昵称
            Text(user.nickname)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(Theme.Palette.matchTitle)

            // meta（年龄 / 性别 / 视频价）
            HStack(spacing: 12) {
                if let age = user.age {
                    Label("\(age)", systemImage: "person.fill")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Palette.matchSubtitle)
                }
                if let price = user.videoPrice, price > 0 {
                    Text(L10n.matchUserCardVideoPrice(price: price))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Palette.matchMarqueeReceiver)
                }
            }

            Spacer()

            // 关闭按钮
            Button {
                dismiss()
            } label: {
                Text(L10n.matchUserCardClose)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Palette.matchTitle)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        Capsule().fill(Theme.Palette.cardFill)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.Palette.screenBackground)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    MatchUserCardSheet(
        user: MatchUserItem.previewFixture(
            userId: "1", nickname: "Alice", age: 25, videoPrice: 800
        )
    )
    .preferredColorScheme(.dark)
}

import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L607-650
/// 视觉：两种形态
///   1) 含 messageImage：max-w-250 rounded-12 · 底图 + 蒙层文字 + 底部 Join 按钮
///   2) 无 messageImage：`.winner-broadcast-box` max-w249 h26 px10 · 跑马灯样式
struct RowWinnerBroadcast: View {
    let activityName: String
    let quantity: Int?
    let imageURL: String?
    let joinCTA: String?
    let avatar: String?
    let theme: PublicChatTheme

    var body: some View {
        if let img = imageURL, !img.isEmpty {
            richForm(imageURL: img)
        } else {
            simpleForm
        }
    }

    /// 大卡形态（带 messageImage）
    private func richForm(imageURL: String) -> some View {
        ZStack(alignment: .topLeading) {
            if let u = URL(string: imageURL) {
                CachedAsyncImage(url: u, contentMode: .fill) {
                    Color.black.opacity(0.3)
                }
                .frame(maxWidth: 250)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let a = avatar, !a.isEmpty {
                        AvatarView(urlString: a, size: 20, kind: .user)
                    }
                    Text(activityName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 216/255, blue: 78/255))   // #FFD84E
                        .lineLimit(2)
                }
                if let q = quantity {
                    Text("×\(q)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                if let cta = joinCTA {
                    Text(cta)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 1.0, green: 148/255, blue: 56/255), in: RoundedRectangle(cornerRadius: 8))   // #FF9438
                }
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 简版跑马灯形态
    private var simpleForm: some View {
        HStack(spacing: 4) {
            Text("Winner Got")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text(activityName)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(red: 1.0, green: 216/255, blue: 78/255))   // #FFD84E
                .lineLimit(1)
            if let q = quantity {
                Text("*\(q)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            Spacer(minLength: 4)
            Text(joinCTA ?? "Join")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(red: 1.0, green: 148/255, blue: 56/255), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 249, minHeight: 26)
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

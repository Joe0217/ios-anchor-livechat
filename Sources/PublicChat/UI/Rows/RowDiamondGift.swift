import SwiftUI

/// H5 源：`anchor-livechat-h5/src/views/liveSetting/components/messageScroller.vue` L524-527
/// H5 组件 `<DiamondGiftChatMessage :item="item">` —— iOS 侧内嵌 4 子类型 switch
/// 4 子类型（PublicChatDiamondGiftSubType）：send / claim / settled / expired
struct RowDiamondGift: View {
    let subType: PublicChatDiamondGiftSubType
    let theme: PublicChatTheme

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: 268, alignment: .leading)
            .background(background)
    }

    @ViewBuilder private var content: some View {
        switch subType {
        case .send(let senderName, let tierName, let totalDiamonds):
            HStack(spacing: 4) {
                Image("coins").resizable().frame(width: 14, height: 14)
                Text(senderName).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text("sent a Diamond Gift Pack").font(.system(size: 12)).foregroundColor(.white)
                if let t = tierName {
                    Text("[\(t)]").font(.system(size: 12, weight: .bold)).foregroundColor(.yellow)
                }
                Text(", \(totalDiamonds)").font(.system(size: 12, weight: .semibold)).foregroundColor(.yellow)
                Image("coins").resizable().frame(width: 12, height: 12)
            }
        case .claim(let userName, let diamonds):
            HStack(spacing: 4) {
                Image(systemName: "hands.sparkles.fill").foregroundColor(.pink).font(.system(size: 14))
                Text(userName).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text("claimed \(diamonds)").font(.system(size: 12)).foregroundColor(.yellow)
                Image("coins").resizable().frame(width: 12, height: 12)
            }
        case .settled(let topUserName, let topDiamonds):
            HStack(spacing: 4) {
                Image(systemName: "crown.fill").foregroundColor(.yellow).font(.system(size: 14))
                Text("Top: \(topUserName)").font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                Text("won \(topDiamonds)").font(.system(size: 12, weight: .semibold)).foregroundColor(.yellow)
                Image("coins").resizable().frame(width: 12, height: 12)
            }
        case .expired(let senderName, let refundDiamonds):
            HStack(spacing: 4) {
                Image(systemName: "arrow.uturn.backward").foregroundColor(.gray).font(.system(size: 14))
                Text("\(senderName)'s pack expired, \(refundDiamonds)").font(.system(size: 12)).foregroundColor(.white).lineLimit(2)
                Image("coins").resizable().frame(width: 12, height: 12)
                Text("refunded").font(.system(size: 12)).foregroundColor(.white).lineLimit(2)
            }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 12).fill(
            LinearGradient(
                colors: [Color(red: 0.3, green: 0.4, blue: 0.7).opacity(0.6),
                         Color(red: 0.5, green: 0.3, blue: 0.7).opacity(0.6)],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }
}

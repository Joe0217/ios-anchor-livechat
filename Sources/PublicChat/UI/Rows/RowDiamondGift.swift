import SwiftUI

/// 钻石福袋公屏：发包、瓜分、结算、退回。结算卡保留 giftId，供主播查看获奖名单。
struct RowDiamondGift: View {
    let subType: PublicChatDiamondGiftSubType
    let theme: PublicChatTheme
    var onTapNickname: (() -> Void)? = nil
    var onTapSettled: ((Int64) -> Void)? = nil

    var body: some View {
        switch subType {
        case .send(_, let senderId, let senderName, _, _):
            HStack(spacing: 6) {
                CDNAssetImage("diamondGiftScreenIcon").resizable().frame(width: 26, height: 26)
                Text(displayName(senderName, fallbackId: senderId)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(L10n.diamondGiftSendAction).font(.system(size: 12)).foregroundStyle(.white)
            }
            .diamondGiftBubble(colors: [Color(hex: 0xA728D9), Color(hex: 0xF35AB7)])
            .contentShape(Rectangle())
            .onTapGesture { onTapNickname?() }

        case .claim(_, let userId, let userName, let diamonds):
            HStack(spacing: 5) {
                Text(L10n.diamondGiftClaim(user: displayName(userName, fallbackId: userId), diamonds: diamonds))
                    .font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
            }
            .diamondGiftBubble(colors: [Color(hex: 0xFF664B), Color(hex: 0xE4AE1A)])
            .contentShape(Rectangle())
            .onTapGesture { onTapNickname?() }

        case .settled(let giftId, let topUserId, let topUserName, let avatarURL, let diamonds):
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.diamondGiftSettledTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                HStack(spacing: 7) {
                    CachedAsyncImage(url: URL(string: avatarURL ?? ""), contentMode: .fill) {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                    settledNickname(displayName(topUserName, fallbackId: topUserId))
                    Spacer(minLength: 2)
                    Text("x\(diamonds)").font(.system(size: 13, weight: .bold)).foregroundStyle(Color(hex: 0xFF33D3))
                    CDNAssetImage("diamondGiftPurpleDiamond").resizable().frame(width: 15, height: 15)
                }
                HStack(spacing: 3) {
                    Text(L10n.diamondGiftViewDetails).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .diamondGiftBubble(colors: [Color(hex: 0x7B2ECC), Color(hex: 0xE83F9A)])
            .contentShape(Rectangle())
            .onTapGesture {
                guard giftId > 0 else { return }
                onTapSettled?(giftId)
            }

        case .expired(_, let senderId, let senderName, _):
            HStack(spacing: 5) {
                Text(L10n.diamondGiftExpired(user: displayName(senderName, fallbackId: senderId)))
                    .font(.system(size: 12)).foregroundStyle(.white).lineLimit(2)
            }
            .diamondGiftBubble(colors: [Color(hex: 0x6D4983), Color(hex: 0xA64F82)])
            .contentShape(Rectangle())
            .onTapGesture { onTapNickname?() }
        }
    }

    private func displayName(_ name: String, fallbackId: String) -> String {
        name.isEmpty ? L10n.diamondGiftUser(fallbackId) : name
    }

    @ViewBuilder
    private func settledNickname(_ name: String) -> some View {
        let label = Text(name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
        if let onTapNickname {
            Button(action: onTapNickname) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(name))
        } else {
            label
        }
    }
}

private extension View {
    func diamondGiftBubble(colors: [Color]) -> some View {
        padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: 268, alignment: .leading)
            .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

import SwiftUI

/// H5 的淘汰/终局结算层。结果完全由 1153/1154 或 /state 下发，不从盘面推导。
///
/// 视觉对齐 H5 `super-wheel-result.vue`：
/// - Win 模式：congrats-bg 330×446 打底缎带+礼盒+光芒 / crown 60×60 头顶 -40 / 头像 110×110 3pt 金边 #FFE9A6 光晕
///   / winner-wing 170×88 -mt-30 / 昵称 14pt 700 #FFD900 / +winAmount 20pt 700 #FFFB00 + 钻石 30×30
///   / 卡片内内容 padding-top 176（让头像落到光芒中心）
/// - Out 模式：**无卡片背景**（H5 rounded-20 但没有 bg 类），只有内容居中：
///   "{name} is out" 16pt 700 → 头像 110×110 3pt 白边 + crying 54×54 右下 → move on 13pt
struct PartySuperWheelResultOverlay: View {
    @ObservedObject var wheelStore: PartySuperWheelStore
    let isRoomOwner: Bool

    private let cardWidthWin: CGFloat = 330
    private let cardHeightWin: CGFloat = 446
    private let avatarSize: CGFloat = 110

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle()).ignoresSafeArea()
            content
        }
        .zIndex(2_000)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var content: some View {
        if wheelStore.resultKind == .winner {
            winCard
        } else if wheelStore.resultKind == .eliminated {
            outCard
        }
    }

    // MARK: Win 模式

    private var winCard: some View {
        let state = wheelStore.wheelState
        let winner = state?.winner
        let name = winner?.nickname ?? L10n.PartyRoom.superWheelPlayer
        let amount = state?.winnerAmount ?? 0
        return ZStack(alignment: .top) {
            CDNAssetImage("superWinnerCongratsBg")
                .resizable()
                .scaledToFit()
                .frame(width: cardWidthWin, height: cardHeightWin)
            winContent(avatarURL: winner?.avatar, name: name, amount: amount)
        }
        .frame(width: cardWidthWin, height: cardHeightWin)
        .overlay(alignment: .topTrailing) { minimizeButton }
    }

    private func winContent(avatarURL: String?, name: String, amount: Int64) -> some View {
        VStack(spacing: 0) {
            winAvatarStack(url: avatarURL)
            CDNAssetImage("superWinnerWinnerWing")
                .resizable()
                .scaledToFit()
                .frame(width: 170, height: 88)
                .offset(y: -30)
            Text(name)
                .font(.system(size: 14, weight: .heavy))
                .foregroundColor(Color(hex: 0xFFD900))
                .lineLimit(1)
                .padding(.top, 2)
                .offset(y: -30)
            HStack(spacing: 4) {
                Text("+\(amount)")
                CDNAssetImage("giftPanelBalanceCoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            }
            .font(.system(size: 20, weight: .heavy))
            .foregroundColor(Color(hex: 0xFFFB00))
            .padding(.top, 20)
            .offset(y: -30)
            .environment(\.layoutDirection, .leftToRight)
            Spacer(minLength: 0)
        }
        .padding(.top, 176)
        .frame(width: cardWidthWin, height: cardHeightWin)
    }

    private func winAvatarStack(url: String?) -> some View {
        CachedAsyncImage(url: url.flatMap(URL.init(string:)), contentMode: .fill, persistent: true) {
            Circle().fill(Color.white.opacity(0.16))
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(hex: 0xFFE9A6), lineWidth: 3))
        .shadow(color: Color(hex: 0xF2B53C).opacity(0.6), radius: 9)
        .overlay(alignment: .top) {
            CDNAssetImage("superWinnerCrown")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .offset(y: -40)
        }
    }

    // MARK: Out 模式（无卡片背景）

    private var outCard: some View {
        let state = wheelStore.wheelState
        let eliminated = state?.revealUser
        let name = eliminated?.nickname ?? L10n.PartyRoom.superWheelPlayer
        return VStack(spacing: 0) {
            Text(String(format: L10n.PartyRoom.superWheelOutFormat, name))
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.bottom, 10)
            outAvatarStack(url: eliminated?.avatar)
            Text(L10n.PartyRoom.superWheelNextRound)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .overlay(alignment: .topTrailing) { minimizeButton }
    }

    private func outAvatarStack(url: String?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            CachedAsyncImage(url: url.flatMap(URL.init(string:)), contentMode: .fill, persistent: true) {
                Circle().fill(Color.white.opacity(0.16))
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white, lineWidth: 3))

            CDNAssetImage("superWinnerCrying")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .offset(x: 18, y: 8)
        }
    }

    // MARK: Top icon(右上最小化,左上关闭按钮已按需求隐藏)

    private var minimizeButton: some View {
        Button(action: onMinimize) {
            CDNAssetImage("superWinnerHeaderBtnLeft")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func onMinimize() {
        wheelStore.dismissResult()
    }
}

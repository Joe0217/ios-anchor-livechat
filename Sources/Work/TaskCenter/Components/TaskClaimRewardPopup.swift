import SwiftUI

/// 领奖成功弹窗。对齐 H5 [`ClaimRewardPopup.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/task/components/ClaimRewardPopup.vue)。
///
/// **rewardType 分派**(与 H5 REWARD_DESC_KEY 对齐):
/// - 1 = Diamonds → `coins` imageset(金橙圆钻)
/// - 2 = Gems → `gems` imageset(蓝色宝石)
/// - 3 = Prop / 4 = Mount / 5 = Frame → SF `gift.fill` 兜底(暂无独立切图)
/// - 6 = Points → SF `star.circle.fill` 兜底
/// - 其他 → 回退到 Diamonds
struct TaskClaimRewardPopup: View {
    let reward: PendingReward
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 12) {
                Text(L10n.taskClaimSuccess)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 22)

                rewardIcon
                    .frame(width: 68, height: 68)
                    .padding(.top, 6)

                // "+数值"
                Text("+\(reward.totalValue)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFFE600))
                    .environment(\.layoutDirection, .leftToRight)  // 对齐 H5 dir="ltr" 保 RTL 下也 "+数值"

                // 奖励类型描述
                Text(rewardDesc)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                // OK
                Button(action: onDismiss) {
                    Text(L10n.commonOK)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(
                            LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
            .frame(width: 280)
            .background(
                LinearGradient(colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                               startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: 0xFA06F4).opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color(hex: 0xFA06F4).opacity(0.35), radius: 8, y: 2)
        }
    }

    // MARK: - rewardType 图标分派(对齐 H5 rewardIcon computed)
    // H5 只对 2/6 用独立图,其余(含 1/3/4/5/未知)全部 fallback 到 diamondYellow(iOS = coins)

    @ViewBuilder
    private var rewardIcon: some View {
        switch reward.rewardType {
        case 2:
            Image("gems").resizable().aspectRatio(contentMode: .fit)
        case 6:
            Image(systemName: "star.circle.fill")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(Color(hex: 0xFFCC00))
        default:
            // 1/3/4/5/未知 —— H5 全部 fallback 到钻石图(iOS 用 coins 切图)
            Image("coins").resizable().aspectRatio(contentMode: .fit)
        }
    }

    // MARK: - rewardType 描述(对齐 H5 REWARD_DESC_KEY)

    private var rewardDesc: String {
        switch reward.rewardType {
        case 2:  return L10n.taskRewardGem
        case 3:  return L10n.taskRewardProp
        case 4:  return L10n.taskRewardMount
        case 5:  return L10n.taskRewardFrame
        case 6:  return L10n.taskRewardPoints
        default: return L10n.taskRewardDiamond   // 1 + fallback
        }
    }
}

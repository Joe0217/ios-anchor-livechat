import SwiftUI

/// B-8 · PK 对战顶部进度条（切图组合还原，对齐设计稿 主播端-PK开始-进行中）。
///
/// 组成（自下而上 z 序）：
/// 1. **两段渐变底色**：我方粉红 `#FF0090→#FF3CC4` / 对方蓝 `#2099FC→#0055FF` 胶囊，按 `myPkValue` 比例分段
/// 2. **进度装饰切图** `pkBattleProgressDecor`（斜纹装饰，overlay 在渐变底之上）
/// 3. **两端 PK badge**：`pkBattleBadgeLeft`（粉）/ `pkBattleBadgeRight`（蓝），30pt 圆
/// 4. **中央动图**：H5 `progress-win/loss/draw.webp`，位于两段进度交界处，safePkProgress 17~83 夹
/// 5. **两侧数字**：黄色 PK 值（我方左 / 对方右，紧接 badge 内侧）
struct PKBattleProgressBar: View {
    let myPkValue: Int
    let opponentPkValue: Int

    /// 2026-07-07 v2 修正：初始 0/0 应 50/50 均分（对齐 H5 livePk.js:110-115 显式 `if total===0 return 50`）；
    /// 原 `max(1, my+opp)` 兜底使双 0 时 progress=0，被 safeClamp 夹到 17% 明显偏左
    private var pkProgress: Double {
        let total = myPkValue + opponentPkValue
        if total == 0 { return 50 }
        return Double(myPkValue) / Double(total) * 100
    }
    private var safePkProgress: Double {
        max(17, min(83, pkProgress))
    }

    private let badgeSize: CGFloat = 16      // 2026-07-06 用户明示两端 PK 圆 16pt
    private let progressAnimationSize: CGFloat = 28  // H5 中央动图 size-28
    private let barHeight: CGFloat = 20      // H5 `h-20` = 20pt

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let myWidth = w * CGFloat(safePkProgress) / 100.0
            let progressAnimationX = myWidth

            ZStack {
                // 1) 两段渐变底色（progressBar 主体色）
                HStack(spacing: 0) {
                    LinearGradient(colors: [Color(hex: 0xFF0090), Color(hex: 0xFF3CC4)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: myWidth)
                    LinearGradient(colors: [Color(hex: 0x2099FC), Color(hex: 0x0055FF)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w - myWidth)
                }
                .frame(height: barHeight)
                .clipShape(Capsule())

                // 2) 装饰切图覆盖（斜纹装饰在渐变底之上）
                CDNAssetImage("pkBattleProgressDecor")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: barHeight)
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // 3+5) badge + number 合并 HStack（2026-07-07 v4 用户反馈"badge 与数字要加间距"）
                // spacing 6 = badge 与 number 之间 gap；padding.horizontal 8 = badge 距容器边缘留白
                HStack(spacing: 6) {
                    CDNAssetImage("pkBattleBadgeLeft")
                        .resizable().frame(width: badgeSize, height: badgeSize)
                    Text("\(myPkValue)")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(Color(hex: 0xFFE600))
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    Spacer()
                    Text("\(opponentPkValue)")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(Color(hex: 0xFFE600))
                        .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    CDNAssetImage("pkBattleBadgeRight")
                        .resizable().frame(width: badgeSize, height: badgeSize)
                }
                .padding(.horizontal, 8)

                // 4) 中央胜/负/平动图悬出条顶 -4pt（对齐 H5 `progress-*.webp`）
                AnimatedGIFView(
                    name: progressAnimationName,
                    fileExtension: "webp",
                    fallbackImageName: "pkBattleHandshake",
                    remoteURL: progressAnimationURL
                )
                    .frame(width: progressAnimationSize, height: progressAnimationSize)
                    .position(x: progressAnimationX, y: progressAnimationSize / 2 - 4)
                    .accessibilityHidden(true)
            }
        }
        // 外框保持 20pt，动图用 position 悬出上下各 4pt；布局空间不被撑高，倒计时紧贴条底。
        .frame(height: barHeight)
    }

    private var progressAnimationName: String {
        if myPkValue == opponentPkValue { return "pk-progress-draw" }
        return myPkValue > opponentPkValue ? "pk-progress-win" : "pk-progress-loss"
    }

    private var progressAnimationURL: URL? {
        URL(string: "https://img.hnhily.link/appId/pk/\(progressAnimationName).webp")
    }
}

import SwiftUI

/// L 里程碑 Match tab：主视觉合成图（星系 + 头像轨道）。
///
/// **不重画图标**：`matchHeroVisual` 切图 = 星系+头像轨道整体视觉。
/// 标题（"N Matches Found!"）已删除（用户反馈）；描述文字由 MatchTabView 独立编排在头像下方。
struct MatchHeroView: View {
    var body: some View {
        Image("matchHeroVisual")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack {
        MatchHeroView()
    }
    .background(Theme.Palette.screenBackground)
    .preferredColorScheme(.dark)
}

import SwiftUI

/// Live Data 规则 sheet —— 对齐 H5 [liveRule/index.vue](anchor-livechat-h5/src/views/liveRule/index.vue) 默认分支
/// 4 小节结构:basic information / data update cycle / income calc rules / exception handling。
///
/// iOS 用 sheet（.large detent）替代 H5 独立 router 页（`router.push('/liveRule')`），
/// 视觉参考 H5：黑背景（#0B0010）+ 黄章节标题（#FFE600）+ 紫子标题（#FA06F4）+ 白正文。
struct LiveRuleSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(no: "I.", title: L10n.liveDataRuleSection1) {
                        rulePair(title: L10n.liveDataRuleTitle1, content: L10n.liveDataRuleContent1)
                    }
                    section(no: "II.", title: L10n.liveDataRuleSection2) {
                        rulePair(title: L10n.liveDataRuleTitle2, content: L10n.liveDataRuleContent2)
                        rulePair(title: L10n.liveDataRuleTitle3, content: L10n.liveDataRuleContent3)
                    }
                    section(no: "III.", title: L10n.liveDataRuleSection3) {
                        rulePair(title: L10n.liveDataRuleTitle4, content: L10n.liveDataRuleContent4)
                        rulePair(title: L10n.liveDataRuleCalcMethod, content: L10n.liveDataRuleContent5)
                    }
                    section(no: "IV.", title: L10n.liveDataRuleSection4) {
                        rulePair(title: L10n.liveDataRuleTitle7, content: L10n.liveDataRuleContent7)
                        rulePair(title: L10n.liveDataRuleTitle8, content: L10n.liveDataRuleContent8)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L10n.liveDataRuleNavTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: 0x0B0010), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    /// 章节:黄色数字标 + 黄色标题 + 内容
    @ViewBuilder
    private func section<C: View>(no: String, title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(no)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFE600))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFE600))
            }
            content()
        }
    }

    /// 单条规则:紫色标题(前缀) + 白色内容;iOS 15+ `Text(a) + Text(b)` 拼接支持独立 style
    /// 注：Text 上的 foregroundStyle(_:) 返 Text 是 iOS 17+；iOS 16 用 foregroundColor(_:) 单参数版
    private func rulePair(title: String, content: String) -> some View {
        (
            Text(title + " ")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(hex: 0xFA06F4))
            + Text(content)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
        )
        .lineSpacing(2)
    }
}

#Preview {
    LiveRuleSheet()
}

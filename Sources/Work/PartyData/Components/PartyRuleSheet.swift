import SwiftUI

/// Party Data 规则 sheet —— 对齐安卓 [PartyRoomDataRuleActivity]（4 小节静态文案）。
/// 4 小节：统计周期定义 / 麦时统计规则 / 收入构成 / 显示规则。
struct PartyRuleSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section(no: "I.", title: L10n.partyDataRuleSection1) {
                        rulePair(title: L10n.partyDataRuleTitle1,
                                 content: L10n.partyDataRuleContent1)
                    }
                    section(no: "II.", title: L10n.partyDataRuleSection2) {
                        rulePair(title: L10n.partyDataRuleTitle2,
                                 content: L10n.partyDataRuleContent2)
                    }
                    section(no: "III.", title: L10n.partyDataRuleSection3) {
                        rulePair(title: L10n.partyDataRuleTitle3,
                                 content: L10n.partyDataRuleContent3)
                    }
                    section(no: "IV.", title: L10n.partyDataRuleSection4) {
                        rulePair(title: L10n.partyDataRuleTitle4,
                                 content: L10n.partyDataRuleContent4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L10n.partyDataRuleNavTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: 0x0B0010), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

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

import SwiftUI

/// Battle Team 规则说明弹窗（对齐 H5 rulesPopup.vue）
///
/// 视觉结构（docs/upload/party房pk规则弹窗.png）：紫底 + PK 剑装饰 + 4 条 bullet + I Know 长按钮
struct PartyBattleRulesPopup: View {
    @Environment(\.dismiss) private var dismiss

    private let rules: [String] = [
        L10n.Party.Battle.rule1,
        L10n.Party.Battle.rule2,
        L10n.Party.Battle.rule3,
        L10n.Party.Battle.rule4,
    ]

    var body: some View {
        ZStack {
            bgGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                heroIcon
                title
                rulesList
                confirmButton
            }
            .padding(.horizontal, 20).padding(.top, 40).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.height(440)])
    }

    @ViewBuilder
    private var heroIcon: some View {
        Image("partyPkBattleMarker")
            .resizable()
            .scaledToFit()
            .frame(width: 60, height: 60)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var title: some View {
        Text(L10n.Party.Battle.rulesTitle)
            .font(.title3).bold()
            .foregroundColor(.white)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var rulesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rules.enumerated()), id: \.offset) { idx, text in
                HStack(alignment: .top, spacing: 5) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text("\(idx + 1). \(text)")
                        .font(.caption)
                        .foregroundColor(.white)
                        .lineSpacing(2)
                }
            }
        }
        .padding(15)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var confirmButton: some View {
        Button {
            dismiss()
        } label: {
            Text(L10n.Party.Battle.iKnow)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(pillGradient)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 22)
    }

    private var bgGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.09, blue: 0.35),   // #17175A
                Color(red: 0.11, green: 0.06, blue: 0.30),   // #1D0E4C
                Color(red: 0.07, green: 0.04, blue: 0.16),   // #130A2A
            ],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
    }

    private var pillGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.52, green: 0.08, blue: 1.0), Color(red: 0.89, green: 0.00, blue: 0.20)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

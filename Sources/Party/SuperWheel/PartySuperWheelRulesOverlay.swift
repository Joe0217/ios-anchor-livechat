import SwiftUI

/// H5 规则正文刻意只维护英文（DM-20260518-001），产品规则变更随客户端版本发布。
///
/// 视觉对齐 H5 `super-wheel-rule.vue`：宽 320，圆角 16，标题 18pt 700 + 3 节内容 + Apple 免责。
/// 章节序号高亮 #FFB100，正文白 82%，分隔线白 12%。
struct PartySuperWheelRulesOverlay: View {
    let onDismiss: () -> Void

    private static let sections: [(title: String, paragraphs: [String])] = [
        (
            "Game Description:",
            [
                "Super winner is a multiplayer interactive game, started by room owners. Players can participate in the game by paying a entrance fee, and the game will start automatically when there are more than 2 players after the countdown.",
            ]
        ),
        (
            "Game rewards:",
            [
                "In each round, one player is eliminated until only one winner remains. The winner receives 80% of the jackpot, the room owner gets 10%.",
                "If the host closes the game midway after players join, or if no winner is produced for any other reason, all fees will be fully refunded to the players, and the host will receive no share.",
            ]
        ),
        (
            "Bets adding session:",
            [
                "each round will have 5s to add bets, the more the bets within the specified time, the greater the winning probability.",
            ]
        ),
    ]

    private static let appleNote = "This game is not related to Apple."

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            container
        }
        .zIndex(2_100)
        .accessibilityAddTraits(.isModal)
    }

    private var container: some View {
        VStack(spacing: 14) {
            Text(L10n.PartyRoom.superWheelRulesTitle)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(.white)
                .padding(.top, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.PartyRoom.superWheelTitle)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.bottom, 14)

                    sectionsColumn
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.black.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .frame(maxHeight: 360)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: 320)
        .background(
            Color(hex: 0x1F1230),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.4))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .accessibilityLabel(Text(verbatim: "Close"))
        }
    }

    private var sectionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 1)
                        .padding(.vertical, 14)
                }
                ruleSection(index: index + 1, title: section.title, paragraphs: section.paragraphs)
            }
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 14)
            Text(Self.appleNote)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.82))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ruleSection(index: Int, title: String, paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(index).")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(Color(hex: 0xFFB100))
                    .environment(\.layoutDirection, .leftToRight)
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(.white)
            }
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.82))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

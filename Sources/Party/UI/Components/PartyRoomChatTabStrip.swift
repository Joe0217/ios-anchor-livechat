import SwiftUI

/// Party 房间聊天区 Tab 切换（All / Chat / Gift）。
///
/// 选中态：黄色文字 + 下方黄色小 underline
enum PartyRoomChatFilter: Int, CaseIterable, Identifiable {
    case all, chat, gift
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: return L10n.PartyRoom.tabAll
        case .chat: return L10n.PartyRoom.tabChat
        case .gift: return L10n.PartyRoom.tabGift
        }
    }
}

struct PartyRoomChatTabStrip: View {
    @Binding var selection: PartyRoomChatFilter

    var body: some View {
        HStack(spacing: Theme.Metric.partyRoomTabGap) {
            ForEach(PartyRoomChatFilter.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metric.partyRoomScreenH)
        .padding(.vertical, Theme.Metric.partyRoomTabV)
    }

    private func tabButton(_ tab: PartyRoomChatFilter) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Text(tab.title)
                    .font(Theme.Typography.partyRoomTab)
                    .foregroundColor(
                        selection == tab
                            ? Theme.Palette.partyRoomTabActive
                            : Theme.Palette.partyRoomTabInactive
                    )
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(selection == tab ? Theme.Palette.partyRoomTabUnderline : Color.clear)
                    .frame(width: Theme.Metric.partyRoomTabUnderlineW,
                           height: Theme.Metric.partyRoomTabUnderlineH)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
    }
}

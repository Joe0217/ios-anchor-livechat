import SwiftUI

/// 派对房顶栏（review 202606252033 P1-6 拆出）。
///
/// 拆出原因：原顶栏在 PartyRoomView body 内引用 `chat.onlineCount` —— chat 是高频
/// ObservableObject（NIM enter/exit 通知频繁），其变化会触发整个 PartyRoomView body 重算 →
/// seatGrid 内 LazyVGrid 重新 evaluate。抽到独立子 view 后 chat 仅本子 view 观测，
/// 麦位区/视频区完全不受影响。
///
/// 入参：
/// - roomName: 房名（衍生自 store.roomInfo.roomName）
/// - chat: 观测 onlineCount（NIM 实时增减，比 store.onlineUserCount 业务快照更新）
/// - roomState: 用于 stateBadge 显色文案
/// - onLeave: 退房按钮回调（由父 view 注入，承接 store.leaveRoom + dismiss）
/// - showSettings: 是否显示右上齿轮入口（房主可见）；nil 时不显示
/// - onTapSettings: 齿轮 tap 回调（父 view 处理 push 到设置页）
struct PartyRoomHeaderView: View {
    let roomName: String
    @ObservedObject var chat: PartyRoomChatManager
    let roomState: PartyRoomState
    let onLeave: () -> Void
    var showSettings: Bool = false
    var onTapSettings: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(roomName)
                    .font(.system(size: 16, weight: .semibold))
                Text(String(format: L10n.Party.onlineCountFormat, chat.onlineCount))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            stateBadge
            if showSettings, let onTapSettings {
                Button(action: onTapSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel(L10n.Party.settingsNavTitle)
            }
            Button(action: onLeave) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
    }

    private var stateBadge: some View {
        let label: String
        let color: Color
        switch roomState {
        case .joined:
            label = L10n.Party.stateJoined
            color = .green
        case .entering, .preparing:
            label = L10n.Party.stateEntering
            color = .orange
        case .leaving:
            label = L10n.Party.stateLeaving
            color = .orange
        case .ended:
            label = L10n.Party.stateEnded
            color = .secondary
        case .idle:
            label = "—"
            color = .secondary
        }
        return Text(label)
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color))
    }
}

import SwiftUI

/// G 里程碑 spec §6 / M3-1：右侧浮动 PK 入口（极简版只 2 按钮）。
///
/// - 仅 `.idle` 时显示；其他态自动隐藏（switch case 同名 view 用 if 链承载，避免 dismantle 重建）
/// - 触发 PKStore.startRandomMatch / 弹 `PKInviteSheet`（由父 view 通过 `showInviteSheet` 触发）
struct PKEntryButton: View {
    @ObservedObject var store: PKStore
    @Binding var showInviteSheet: Bool

    var body: some View {
        // H5 同步：.idle 或 .inviting 都可见（.inviting 允许追加邀请直至 5 个上限）
        if store.state == .idle || store.state == .inviting {
            HStack(spacing: 10) {
                // 随机匹配按钮：仅 .idle 显示（H5 一旦进入 .inviting 不能再发匹配）
                if store.state == .idle {
                    Button {
                        Task { await store.startRandomMatch() }
                    } label: {
                        iconButton(system: "shuffle", title: L10n.PK.entryRandom)
                    }
                }
                // 邀请按钮：.idle 或 .inviting 都显示；满 5 个邀请时禁用
                Button {
                    showInviteSheet = true
                } label: {
                    iconButton(system: "person.crop.circle.badge.plus",
                               title: inviteLabel)
                }
                .disabled(store.invitedAnchors.count >= 5)
                .opacity(store.invitedAnchors.count >= 5 ? 0.5 : 1.0)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
        }
    }

    /// 邀请按钮标签：.idle 显示 "邀请"；.inviting 显示 "邀请 N/5"
    private var inviteLabel: String {
        let count = store.invitedAnchors.count
        if count == 0 {
            return L10n.PK.entryInvite
        } else {
            return "\(L10n.PK.entryInvite) \(count)/5"
        }
    }

    private func iconButton(system: String, title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: system).font(.title3)
            Text(title).font(.system(size: 11)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(width: 60, height: 60)
        .background(LinearGradient(colors: [.pink, .purple],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

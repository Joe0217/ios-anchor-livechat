import SwiftUI

/// 派对房 tools sheet 枚举（PartyRoomView 用 enum-driven 单 sheet 切换）
enum PartyRoomToolSheetKind: String, Identifiable {
    case tools, settings, blocklist
    // spec §3 Sheet Mount Hoist 新增（swiftui-fullscreencover-hoist rule）：
    // Room Mode + Mic Application 相关 modal 全部 hoist 到 PartyRoomView 单一 enum
    case roomMode
    case roomModeConfirm
    case micApplicationList
    case micApplicationSwitchConfirm
    var id: String { rawValue }
}

/// 派对房「Room Tools」sheet — 房主/房管 tap 顶栏齿轮时弹起。
///
/// **对齐 H5 用户端** `livechat-h5/src/components/party/components/room-mana-popup.vue`：
/// - 底部 sheet + 3 列网格 + 顶部居中标题 "Room Tools"
/// - 各项按 role 显示（Owner-only 项：Lock Room / Room Mode / MC Seat；Owner + PlatformAdmin：MC Seat；全部房管：Music / Mic Application / Blocklist / Settings）
/// - iOS MVP：Settings/Blocklist tap 触发导航；其余项 stub log（真机可见项以定位后端 wiring 完成度）
///
/// 用 enum-driven 单 sheet 切换（tools ↔ settings）避免 iOS 16 双 sheet race。
struct PartyRoomToolsSheet: View {
    /// 房主 or 平台管理员判定（决定 Owner-only 项可见）
    let isOwner: Bool
    /// 平台管理员（非房主）判定（MC Seat 也允许）
    let isPlatformAdmin: Bool
    let onTapSettings: () -> Void
    let onTapBlocklist: () -> Void
    /// spec §3 wire：Room Mode item tap → 关本 sheet + 350ms 后打开 activeRoomTool = .roomMode
    let onTapRoomMode: () -> Void
    /// spec §3 wire：Mic Application item tap → 关本 sheet + 350ms 后打开 activeRoomTool = .micApplicationList
    let onTapMicApplication: () -> Void
    /// 其他 stub 项 tap 通用回调（View 可 toast "Coming soon"）
    let onTapStub: (String) -> Void

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 20), count: 3)

    var body: some View {
        ZStack {
            Theme.Palette.partyListBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                Text(L10n.Party.settingsToolsTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.top, 24)
                    .padding(.bottom, 12)
                LazyVGrid(columns: columns, spacing: 24) {
                    if isOwner {
                        toolItem(icon: "lock.fill", label: L10n.Party.toolLockRoom) {
                            onTapStub(L10n.Party.toolLockRoom)
                        }
                    }
                    toolItem(icon: "music.note", label: L10n.Party.toolMusic) {
                        onTapStub(L10n.Party.toolMusic)
                    }
                    toolItem(icon: "gearshape.fill", label: L10n.Party.toolSettings, isPrimary: true) {
                        onTapSettings()
                    }
                    toolItem(icon: "hand.raised.fill", label: L10n.Party.toolMicApplication) {
                        onTapMicApplication()
                    }
                    if isOwner {
                        toolItem(icon: "square.grid.2x2.fill", label: L10n.Party.toolRoomMode) {
                            onTapRoomMode()
                        }
                    }
                    toolItem(icon: "person.crop.circle.badge.minus", label: L10n.Party.toolBlocklist) {
                        onTapBlocklist()
                    }
                    if isOwner || isPlatformAdmin {
                        toolItem(icon: "mic.fill", label: L10n.Party.toolMCSeat) {
                            onTapStub(L10n.Party.toolMCSeat)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }

    private func toolItem(icon: String, label: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            isPrimary
                            ? AnyShapeStyle(LinearGradient(
                                colors: [Theme.Palette.partyCreateBtnA, Theme.Palette.partyCreateBtnB],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            : AnyShapeStyle(Color.white.opacity(0.08))
                        )
                        .frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// PK 入口按钮 — 5 态单按钮（对齐 H5 `pkEntryBtn.vue`）。
///
/// 状态映射（[PKStore.State](../PKModels.swift) → H5 `PK_STATUS`）：
/// - `.idle` / `.inviting` → default（默认 PK 图标，点击弹发起 PK 弹窗）
/// - `.matching`         → matching（旋转搜索动画，点击弹发起 PK 弹窗查看/取消）
/// - `.invited`          → invited（60s 倒计时数字，点击弹接收邀请弹窗）
/// - `.starting` / `.inPK` → inPK（PK 中态；点击暂 toast "PK 中"——B-2 中断确认弹窗未做）
/// - `.punishing`        → punishing（惩罚态；点击暂 toast "惩罚中"——B-3 断开确认弹窗未做）
/// - `.endingPK` / `.failed` / `.ended` → 隐藏
///
/// 视觉：40x40 圆按钮 + 品红→紫渐变，中央按 5 态切换 icon / 倒计时数字。
struct PKEntryButton: View {
    @ObservedObject var store: PKStore
    @Binding var showInviteSheet: Bool
    /// inPK 态点击 → 打开中断确认弹窗（B-2 PKInterruptConfirmPopup）
    let onInterruptTap: () -> Void
    /// punishing 态点击 → 打开断开连线确认弹窗（B-3 PKDisconnectConfirmPopup）
    let onDisconnectTap: () -> Void

    var body: some View {
        Group {
            switch store.state {
            case .endingPK, .failed:
                EmptyView()
            case .idle, .inviting, .starting, .inPK, .punishing:
                // 3 个「静默」态 - 使用 `liveRoomPKIcon` 切图（Frame 948 多彩 PK 字）
                // 对齐 H5 pkEntryBtn.vue L82-104：default / IN_PK / PUNISHING 都用 pk-btn-living.webp
                Button(action: handleTap) {
                    CDNAssetImage("liveRoomPKIcon")
                        .resizable()
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .accessibilityLabel(Text(a11yLabel))
            default:
                // 特殊态（.matching / .invited）保留 SwiftUI 渐变圆 + 特殊 content（loading / 60s 倒计时）
                Button(action: handleTap) {
                    ZStack {
                        Circle()
                            .fill(background)
                            .frame(width: 40, height: 40)
                        content
                    }
                    .contentShape(Circle())
                }
                .accessibilityLabel(Text(a11yLabel))
            }
        }
    }

    // MARK: - Behavior

    private func handleTap() {
        switch store.state {
        case .idle, .inviting, .matching:
            showInviteSheet = true
        case .invited:
            // PKInvitedSheet 由 PKOverlayHost 在 state==.invited 时自动覆盖显示（LiveRoomView.swift PKOverlayHost），
            // 此处按 H5 pkEntryBtn.vue L86 语义：点击按钮 = 弹接收邀请 UI。iOS 已自动展示，无需二次触发。
            break
        case .starting, .inPK:
            onInterruptTap()
        case .punishing:
            onDisconnectTap()
        case .endingPK, .failed:
            break
        }
    }

    // MARK: - Visuals

    /// 5 态渐变背景（.invited 描边风格，其余粉紫渐变）
    private var background: LinearGradient {
        switch store.state {
        case .invited:
            return LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                  startPoint: .leading, endPoint: .trailing)
        case .matching:
            return LinearGradient(colors: [Color(hex: 0xFD79C1), Color(hex: 0xBC53F5)],
                                  startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(colors: [Color(hex: 0xFD79C1), Color(hex: 0x8515FF)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .invited:
            // 显示 60s 倒计时数字（H5 pk-be-invited-countdown-bg 视觉近似）
            Text("\(max(0, store.inviteRemainingSeconds))s")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.white)
                .shadow(color: Color(hex: 0x8515FF), radius: 2, x: 0, y: 1)
        case .matching:
            // 旋转 loading 图标（近似 pk-btn-matching 动画）
            RotatingIcon(systemName: "arrow.triangle.2.circlepath")
        case .starting, .inPK:
            Text("PK").font(.system(size: 14, weight: .heavy)).foregroundColor(.white)
        case .punishing:
            Image(systemName: "hourglass").font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        default:
            // default (.idle / .inviting) — PK 双人图标
            Image(systemName: "person.2.fill").font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var a11yLabel: String {
        switch store.state {
        case .invited:   return L10n.liveRoomPKA11yInvited
        case .matching:  return L10n.liveRoomPKA11yMatching
        case .inPK, .starting: return L10n.liveRoomPKA11yInPK
        case .punishing: return L10n.liveRoomPKA11yPunishing
        default:         return L10n.liveRoomPKA11yDefault
        }
    }
}

/// 旋转图标（matching 态搜索动画）
private struct RotatingIcon: View {
    let systemName: String
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

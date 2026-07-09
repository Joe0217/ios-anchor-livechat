import SwiftUI

/// H-3 顶部宝箱进度条（Batch 6.1，对齐 H5 `rewardProgress.vue`）。
///
/// **对齐设计稿**（`消息UI/私聊页切图位置.png` 顶部宝箱条）：
/// - 容器 h64（≈52-58）圆角 12 深紫渐变
/// - 进度轨道 h8 圆角、底色 #feebd2、填充 orange→yellow linear-gradient
/// - 3 个宝箱节点绝对定位 30%/60%/93%，节点含宝箱 icon + diamond 值气泡
/// - 右侧奖励记录按钮（29x52 rounded-7 bg-#2C1F46）
///
/// **数据源**：`ReplyPointsStore.shared.sessions[peer]`
/// - `messageBoxList[]`（全部宝箱）+ `currentProgress`（累加值）
/// - Store 层 `beginSession(peer)` 已 auto-claim；本 view 只做展示
///
/// **可见 3 节点 slice**（H5 `setVisibleList`）：
/// - list.count ≤ 3 → 全部
/// - list.count > 3 → 找 currentProgress <= item.points 的第一个 idx；取 [idx, idx+3)；末尾不足取 last 3
struct RewardProgressView: View {

    let peer: String
    @ObservedObject var store: ReplyPointsStore
    /// 历史按钮 tap 回调（Batch 6.1.4 hoist popup 到 ChatDetailView，避免 overlay 层级被消息气泡遮挡）
    var onTapRecords: (() -> Void)? = nil

    var body: some View {
        // 无条件占位 76pt(64pt 容器 + 12pt top padding)防"进入页面 500ms 后 messageBoxList
        // 到达导致 76pt 忽现挤压消息列表"的 layout shift。isOpenPaidMessage=false 时容器保持
        // 透明占位(Color.clear + opacity 0),layout 稳定但视觉无痕。
        // 注:caller ChatDetailView 已 gate chatType == .regular,此处不重复判定 chatType。
        Group {
            if store.isOpenPaidMessage(peer: peer) {
                HStack(spacing: 8) {
                    progressRow
                        .frame(maxWidth: .infinity)
                    recordsButton
                }
                .padding(.leading, 14)
                .padding(.trailing, 8)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x150E20), Color(hex: 0x1B122D)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            } else {
                Color.clear
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    // MARK: - 进度条 + 节点

    private var progressRow: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 底色轨道
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: 0xFEEBD2))
                    .frame(height: 8)
                    .padding(.top, 36)   // 让宝箱节点从上方压过来

                // 填充
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xEF4444), Color(hex: 0xF59E0B), Color(hex: 0xFBBF24)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(progressPercent) / 100.0, height: 8)
                    .padding(.top, 36)
                    .animation(.easeOut(duration: 0.5), value: progressPercent)

                // 起始位置金币 icon（切图 RewardBoxCoin 缩小版 —— 设计稿"私聊页切图位置.png"左边起点标注 `Coins`）
                Image("RewardBoxCoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .position(x: 6, y: 40)   // padding.top 36 + track h8/2

                // 3 节点
                ForEach(Array(visibleList.enumerated()), id: \.offset) { idx, item in
                    boxNode(item)
                        .position(x: geo.size.width * nodePosition(idx) / 100.0, y: 22)
                }
            }
        }
        .frame(height: 52)
    }

    private func boxNode(_ item: MessageBoxItem) -> some View {
        VStack(spacing: 4) {
            // 宝箱图（切图 RewardBoxCoin —— 对齐设计稿 `消息列表_slices/Coins.png` 橙色金币宝箱）
            ZStack {
                Image("RewardBoxCoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                // 已领取：半透明黑底 + 勾（对齐 H5 rewardProgress.vue `get-icon.webp` 遮罩）
                if item.status == .claimed {
                    RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.5))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            // diamond 数值气泡
            let reached = currentProgress >= item.points
            Text("+\(item.diamond)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 16)
                .background {
                    if reached {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xFF9826), Color(hex: 0xFE6828)],
                                                 startPoint: .trailing, endPoint: .leading))
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(hex: 0x3B2B58))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(reached ? Color.white.opacity(0.25) : Color(hex: 0x3B2B58), lineWidth: 1)
                )
        }
    }

    // MARK: - 右侧 records 按钮

    private var recordsButton: some View {
        Button {
            onTapRecords?()
        } label: {
            // 切图 RewardRecord —— 设计稿 Frame 390 已含紫色圆角底 + 时钟 icon，整图 29x52 直接用
            // 修：原叠一层 RoundedRectangle 紫色底导致视觉双重底 + icon 显淡；直接用切图整图
            Image("RewardRecord")
                .resizable()
                .scaledToFit()
                .frame(width: 29, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reward Records")
    }

    // MARK: - 派生数据

    private var currentProgress: Int {
        store.sessions[peer]?.currentProgress ?? 0
    }

    /// 可见 3 节点窗口（对齐 H5 `setVisibleList(node=3)`）
    private var visibleList: [MessageBoxItem] {
        let all = store.sessions[peer]?.messageBoxList ?? []
        guard all.count > 3 else { return all }
        let cp = currentProgress
        // 找第一个 points >= currentProgress 的 idx
        if let idx = all.firstIndex(where: { $0.points >= cp }) {
            if idx + 3 <= all.count {
                return Array(all[idx..<(idx + 3)])
            }
            // 末尾不足取 last 3
            return Array(all.suffix(3))
        }
        // 全部已过 → 取 last 3
        return Array(all.suffix(3))
    }

    /// 节点位置（对齐 H5 `getNodePosition`：30/60/93）
    private func nodePosition(_ idx: Int) -> CGFloat {
        switch idx {
        case 0: return 30
        case 1: return 60
        case 2: return 93
        default: return 100
        }
    }

    /// 进度百分比（对齐 H5 `progressPercent`：3 段线性映射）
    private var progressPercent: CGFloat {
        let nodes = visibleList
        let cp = currentProgress
        guard cp > 0, !nodes.isEmpty else { return 0 }

        let positions: [CGFloat] = [30, 60, 93]
        for i in 0..<nodes.count {
            let nodePts = nodes[i].points
            let prevPts = i == 0 ? 0 : nodes[i - 1].points
            let prevPos = i == 0 ? 0 : positions[i - 1]
            let curPos = positions[i]
            if cp <= nodePts {
                let range = CGFloat(nodePts - prevPts)
                guard range > 0 else { return curPos }
                let ratio = CGFloat(cp - prevPts) / range
                return prevPos + ratio * (curPos - prevPos)
            }
        }
        return 100
    }
}

// Color(hex:) 已在 Sources/Message/UI/UserLevelBadge.swift 和 ChatColors.swift 提供，本文件复用

import SwiftUI

/// H-3 奖励记录弹窗（Batch 6.1.2，对齐 H5 `rewardRecordsPop.vue` + 设计稿 `总览弹窗查询.png`）。
///
/// **视觉**（对齐设计稿）：
/// - 圆角紫色卡片 w319 h~345，内边距 24 顶部 40 底部 24；渐变紫底 `#3800A0 → #5300A1`
/// - 顶部两行 Free/Paid Message + points（浅紫底 0.3 opacity）
/// - 表头：Points / Reward💎 / Time
/// - 记录列表：滚动 max-h ~200
/// - 右上关闭 X（圆形白底）
///
/// **数据**：
/// - `records: [MessageBoxRecordItem]` 由 caller 通过 `ReplyPointsService.fetchMessageBoxRecords` 拉取传入
/// - `freeMessagePoints / paidMessagePoints` 从 caller AppConfigStore 派生
struct RewardRecordsPopup: View {
    let records: [MessageBoxRecordItem]
    let freeMessagePoints: Int
    let paidMessagePoints: Int
    let isLoading: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // 遮罩
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // 卡片
            card
        }
    }

    private var card: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    labelRow(left: "Free Message", right: "+\(freeMessagePoints) Points")
                    labelRow(left: "Paid Message", right: "+\(paidMessagePoints) Points")
                    headerRow
                    recordsList
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 24)

                closeButton
                    .padding(.top, 10)
                    .padding(.trailing, 10)
            }
        }
        .frame(width: 319)
        .background(
            LinearGradient(colors: [Color(hex: 0x3800A0), Color(hex: 0x5300A1)],
                           startPoint: .bottom, endPoint: .top),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    // MARK: - Rows

    private func labelRow(left: String, right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .frame(height: 24)
        .padding(.horizontal, 8)
        .background(Color(hex: 0x2B213E).opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Points")
                .frame(maxWidth: .infinity)
            HStack(spacing: 2) {
                Text("Reward")
                Image(systemName: "diamond.fill")
                    .foregroundStyle(Color(hex: 0x66CCFF))
            }
            .frame(maxWidth: .infinity)
            Text("Time")
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .frame(height: 24)
        .padding(.horizontal, 8)
        .background(Color(hex: 0x2B213E).opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private var recordsList: some View {
        if isLoading {
            ProgressView().tint(.white.opacity(0.6))
                .frame(height: 60)
        } else if records.isEmpty {
            Text("No records yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(height: 60)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(records) { r in
                        recordRow(r)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func recordRow(_ r: MessageBoxRecordItem) -> some View {
        HStack(spacing: 0) {
            Text("\(r.point)")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
            Text("+\(r.diamond)")
                .foregroundStyle(Color(hex: 0xE9A65B))
                .frame(maxWidth: .infinity)
            Text(Self.formatDate(r.createTime))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12, weight: .medium))
        .frame(height: 24)
        .padding(.horizontal, 8)
    }

    // MARK: - Close

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: 0x3800A0))
                .frame(width: 24, height: 24)
                .background(Color.white, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }

    // MARK: - Helpers

    /// ms 时间戳 → "yyyy-MM-dd"（对齐 H5 dayjs `YYYY-MM-DD`）
    private static func formatDate(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

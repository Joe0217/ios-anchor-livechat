import SwiftUI

/// Weekly 大 R 任务卡。对齐 H5 [`views/task/index.vue`](../../../../../Desktop/HN/anchor-livechat-h5/src/views/task/index.vue) L343-375 内部裸行。
/// 视觉:任务标题 + 描述 + 进度条 + 奖励值。
struct TaskTycoonCard: View {
    let task: ActiveTycoonTaskVO

    private var progressRatio: CGFloat {
        guard task.targetValue > 0 else { return 0 }
        return min(1, CGFloat(task.progressValue) / CGFloat(task.targetValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.taskTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xFFCC00))
                    Text("×\(task.rewardAmount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xFFE600))
                }
            }
            if let desc = task.taskDesc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }
            // 进度条 + 数值
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                            .frame(height: 6)
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(hex: 0xF640DC), Color(hex: 0x8515FF)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progressRatio, height: 6)
                    }
                }
                .frame(height: 6)
                Text("\(task.progressValue) / \(task.targetValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x191423))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

import SwiftUI

/// Tab2 Active Tycoon Task 视图:多阶段任务列表(无分页)。
///
/// 对齐 H5 `activeTycoonTaskTab.vue`:
/// - 每项 mb-12 rounded-16 p-15 + 卡片渐变(同 Tab1)
/// - 上行:taskTitle 14pt bold + rewardAmount(>0)+ coins
/// - 中行:进度条 h14 w220 + progressValue/targetValue
/// - taskDesc 存在时显示 12pt white/50
/// - `reachFlag == 1` 显 completed 绿色文案
struct LiveGiftTaskTab2View: View {
    @ObservedObject var store: ActiveTycoonTaskStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                content
            }
            .padding(.horizontal, 15)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .task {
            await store.loadAsync()
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.tasks.isEmpty {
            HStack {
                Spacer()
                Text(L10n.liveRoomTaskTycoonLoading)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            .padding(.vertical, 40)
        } else if store.tasks.isEmpty {
            HStack {
                Spacer()
                Text(L10n.liveRoomTaskTycoonEmpty)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            .padding(.vertical, 40)
        } else {
            ForEach(store.tasks) { task in
                LiveGiftTaskTycoonRow(task: task)
            }
        }
    }
}

// MARK: - 单条 tycoon 行

struct LiveGiftTaskTycoonRow: View {
    let task: ActiveTycoonTaskVO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.taskTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if task.rewardAmount > 0 {
                    HStack(spacing: 2) {
                        CDNAssetImage("coins")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text("\(task.rewardAmount)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: 0xFFD700))
                    }
                }
            }
            HStack {
                LiveGiftProgressBar(
                    currentPoints: Int64(task.progressValue),
                    totalPoints: Int64(task.targetValue),
                    innerGradientColors: LiveGiftProgressBar.activeTycoonGradient
                )
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    CDNAssetImage("coins")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                    Text("\(task.progressValue)/\(task.targetValue)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            if let desc = task.taskDesc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            if task.reachFlag == 1 {
                Text(L10n.liveRoomTaskTycoonCompleted)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0x17DC74))
                    .padding(.top, 4)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var cardBackground: some View {
        LinearGradient(
            colors: [Color(hex: 0x30296D, opacity: 0.3), Color(hex: 0x31248C, opacity: 0.3)],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

// MARK: - Preview

#if DEBUG
struct LiveGiftTaskTab2View_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LiveGiftTaskTab2View(store: {
                let s = ActiveTycoonTaskStore()
                Task { await s.loadAsync() }
                return s
            }())
            .previewDisplayName("Loaded")

            LiveGiftTaskTab2View(store: ActiveTycoonTaskStore(
                service: LiveGiftTaskServiceFakes(mode: .empty)))
            .previewDisplayName("Empty")

            LiveGiftTaskTab2View(store: ActiveTycoonTaskStore(
                service: LiveGiftTaskServiceFakes(mode: .error("timeout"))))
            .previewDisplayName("Error")
        }
        .frame(height: 400)
        .background(LinearGradient(colors: [Color(hex: 0x17175A), Color(hex: 0x1D0E4C), Color(hex: 0x130A2A)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading))
        .previewLayout(.sizeThatFits)
    }
}
#endif

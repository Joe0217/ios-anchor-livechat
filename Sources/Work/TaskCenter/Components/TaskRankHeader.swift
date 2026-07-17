import SwiftUI

/// Task 页顶部排位卡。设计稿:**单卡通栏**(切图 taskRankCardBg 铺满)+ 左右 2 大 3D 奖杯/勋章切图。
///
/// 奖杯切图内含占位"999"(切图艺术资源自带) —— iOS 用后端真数值 overlay 覆盖切图占位。
/// 数字位置:垂直居中于奖杯下方橙色横条(从视觉判断约在奖杯高度的 70% 处)。
struct TaskRankHeader: View {
    let rank: TaskRankInfoVO?
    let onIncomeTap: () -> Void
    let onIntegralTap: () -> Void

    var body: some View {
        ZStack {
            // `.resizable()` + frame(height:) + frame(maxWidth: .infinity) 让图片水平拉伸铺满
            // 不用 aspectRatio(.fill) 避免按图片原比例撑大超出屏宽
            Image("taskRankCardBg")
                .resizable()
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 0) {
                cell(icon: "taskRankTrophy",
                     value: rank?.myIncome,
                     label: L10n.taskGlobalIncome,
                     onTap: onIncomeTap)
                cell(icon: "taskRankMedal",
                     value: rank?.myIntegral,
                     label: L10n.taskPoints,
                     onTap: onIntegralTap)
            }
            .padding(.vertical, 12)
        }
        .frame(height: 130)
    }

    private func cell(icon: String,
                      value: Int?,
                      label: String,
                      onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                // 奖杯切图 + 覆盖真数据数字(切图内 999 是占位,iOS 数据覆盖它)
                ZStack {
                    Image(icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 82)
                    // 数字覆盖切图橙色横条区域(切图橙条在图底部约 25% 处 —— 数字 y 位移调整对齐)
                    Text(value.map { "\($0)" } ?? "--")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(y: 22)
                }
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

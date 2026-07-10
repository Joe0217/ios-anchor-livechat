import SwiftUI

/// 转盘可视化（对齐 H5 liveRoulettePopup.vue 中央 250×250 conic-gradient 转盘）
///
/// 结构（ZStack 分层）：
/// 1. 底盘：圆形 conic-gradient 效果（用 `Path.addArc` 画 N 扇形，灰色 #504E4D / #3A3736 交替）
/// 2. 分隔线：每两扇形之间画 1 条深黑 (#151515) radial 线
/// 3. 文字：每个扇形中心方向贴 rotated `Text`
/// 4. 中央装饰环：轻描白圆环，突出圆心（H5 用 roulette.webp 背景图；此处纯代码等效简化）
///
/// **性能**：4-8 扇形 = 40 vertices 级 SwiftUI Canvas 绘制，静态渲染，无动画开销
struct RouletteWheelView: View {
    /// 已补齐到 4-8 的 sectors（由 Store.displaySectors 提供）
    let sectors: [RouletteSector]
    /// 转盘直径（默认 214，对齐 H5 内圈尺寸）
    var diameter: CGFloat = 214

    private var count: Int { max(sectors.count, 1) }
    private var anglePerSector: Double { 360.0 / Double(count) }

    var body: some View {
        ZStack {
            // (1) 扇形底盘
            Canvas { ctx, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2
                for i in 0..<count {
                    let startDeg = Double(i) * anglePerSector - 90  // -90 让第 1 扇形从 12 点方向开始
                    let endDeg = startDeg + anglePerSector
                    var path = Path()
                    path.move(to: center)
                    path.addArc(center: center,
                                radius: radius,
                                startAngle: .degrees(startDeg),
                                endAngle: .degrees(endDeg),
                                clockwise: false)
                    path.closeSubpath()
                    let fill: Color = (i % 2 == 0) ? Color(hex: 0x504E4D) : Color(hex: 0x3A3736)
                    ctx.fill(path, with: .color(fill))
                }
                // 分隔线（每扇形边界）
                for i in 0..<count {
                    let deg = Double(i) * anglePerSector - 90
                    let rad = deg * .pi / 180
                    let endPoint = CGPoint(x: center.x + cos(rad) * radius,
                                           y: center.y + sin(rad) * radius)
                    var line = Path()
                    line.move(to: center)
                    line.addLine(to: endPoint)
                    ctx.stroke(line, with: .color(Color(hex: 0x151515)), lineWidth: 2)
                }
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())

            // (2) 文字（旋转贴合扇形中心方向）
            ForEach(Array(sectors.enumerated()), id: \.element.id) { idx, sector in
                let midDeg = Double(idx) * anglePerSector + anglePerSector / 2.0 - 90.0
                sectorText(sector: sector, midDeg: midDeg)
            }

            // (3) 中央小圆装饰
            Circle()
                .fill(Color(hex: 0x2A2828))
                .frame(width: 32, height: 32)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
        .frame(width: diameter, height: diameter)
    }

    private func sectorText(sector: RouletteSector, midDeg: Double) -> some View {
        // 文字从圆心向外沿 midDeg 方向偏移到扇形中部（半径 60% 处）
        let rad = midDeg * .pi / 180
        let offset = diameter * 0.32   // 距圆心的距离
        let dx = cos(rad) * offset
        let dy = sin(rad) * offset
        let isLast = sector.isPlaceholder
        return Text(sector.text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(isLast ? Color.white.opacity(0.3) : Color.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: diameter * 0.35)
            // 让文字沿扇形径向朝外可读（+90° 让 baseline 与径向垂直，即"面向圆心朝外"）
            .rotationEffect(.degrees(midDeg + 90))
            .offset(x: dx, y: dy)
    }
}

#if DEBUG
struct RouletteWheelView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 30) {
            RouletteWheelView(sectors: [
                RouletteSector(presetId: "1", text: "Kiss"),
                RouletteSector(presetId: "2", text: "Wink"),
                RouletteSector(presetId: "3", text: "Dance"),
                RouletteSector(presetId: "4", text: "Sing"),
            ])
            RouletteWheelView(sectors: [
                RouletteSector(presetId: "1", text: "Kiss"),
                RouletteSector(presetId: "2", text: "Wink"),
                RouletteSector(presetId: "3", text: "Dance"),
                RouletteSector(presetId: "4", text: "Sing"),
                RouletteSector(presetId: "5", text: "Blow Kiss"),
                RouletteSector(presetId: "6", text: "Wave"),
                RouletteSector(presetId: "7", text: "Smile"),
                RouletteSector(presetId: "", text: "Pending edit", isPlaceholder: true),
            ])
        }
        .padding()
        .background(Color(hex: 0x242221))
    }
}
#endif

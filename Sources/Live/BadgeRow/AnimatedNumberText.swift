import SwiftUI

/// 数字滚动动画 Text（对齐 H5 `AnimatedNumber` 组件 easeOutExpo 600ms 缓动）
struct AnimatedNumberText: View {
    let value: Int64
    var body: some View {
        if #available(iOS 17.0, *) {
            Text("\(value)")
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.6), value: value)
        } else {
            Text("\(value)")
                .animation(.easeOut(duration: 0.6), value: value)
        }
    }
}

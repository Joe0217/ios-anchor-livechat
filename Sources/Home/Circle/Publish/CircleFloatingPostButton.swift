import SwiftUI

/// Circle 容器右下角发布朋友圈浮动按钮（J spec §7 Q1/Q2）。
///
/// 视觉风格参考 [PKEntryButton.swift:47-59](../../PK/UI/PKEntryButton.swift#L47-L59)：
/// 60×60 圆角胶囊 + LinearGradient(pink→purple) + shadow + SF Symbol。
/// 设计稿到位前用 SF Symbol `square.and.pencil` 占位。
struct CircleFloatingPostButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(colors: [.pink, .purple],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing),
                    in: Circle()
                )
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Publish.fabLabel)
    }
}

#if DEBUG
struct CircleFloatingPostButton_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.ignoresSafeArea()
            CircleFloatingPostButton { }
                .padding(.trailing, 16)
                .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

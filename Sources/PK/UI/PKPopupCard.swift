import SwiftUI

/// H5 pkLive/*Popup.vue 通用 popup 容器（gradient card + close X + title + content slot）。
///
/// 视觉规范（对齐 H5 [pkInterruptConfirmPopup.vue](../../../.././anchor-livechat-h5/src/views/liveSetting/components/pkLive/pkInterruptConfirmPopup.vue) style）：
/// - 全屏半透黑蒙层（`rgba(0,0,0,0.5)`）
/// - 中央卡片：宽 85%（≤ 320pt），圆角 20，渐变背景 `#5300A1 → #3800A0`
/// - 右上关闭 X 按钮（20x20）
/// - 顶部标题（18pt bold 白）
/// - 内容 slot（padding: 24 x 32 / bottom 32）
///
/// 用法：
/// ```swift
/// PKPopupCard(isPresented: $show, title: "Title") {
///     Text("body")
///     PKPopupButtonRow { ... }
/// }
/// ```
struct PKPopupCard<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: () -> Content
    /// 顶部标题旁的附加图标按钮（例如 pkInviteReceivePopup 的规则问号），nil 则不显示
    var titleTrailing: (() -> AnyView)? = nil

    init(isPresented: Binding<Bool>,
         title: String,
         titleTrailing: (() -> AnyView)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self._isPresented = isPresented
        self.title = title
        self.titleTrailing = titleTrailing
        self.content = content
    }

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    // H5 close-on-click-overlay 各弹窗策略不一：本项目统一保留 X 关闭为唯一路径
                    // （对齐 pkInviteReceivePopup close-on-click-overlay=false）

                VStack(alignment: .center, spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: 0) {
                            HStack(alignment: .center, spacing: 8) {
                                Spacer(minLength: 0)
                                Text(title)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                if let trailing = titleTrailing {
                                    trailing()
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 24)
                            .padding(.horizontal, 40)  // 让开右上关闭 X

                            content()
                                .padding(.horizontal, 24)
                                .padding(.top, 20)
                                .padding(.bottom, 24)
                        }
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 20, height: 20)
                                .background(Color.white.opacity(0.15), in: Circle())
                                .contentShape(Circle())
                        }
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                        .accessibilityLabel(Text(L10n.liveRoomCloseA11y))
                    }
                }
                .frame(maxWidth: 320)
                .background(
                    LinearGradient(colors: [Color(hex: 0x5300A1), Color(hex: 0x3800A0)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 20)
                )
                .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }
}

/// H5 pk popup 两按钮 row（对齐 pkInterruptConfirmPopup.vue L67-89 双 van-button 布局）。
struct PKPopupButtonRow<Left: View, Right: View>: View {
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    var body: some View {
        HStack(spacing: 12) {
            left()
            right()
        }
    }
}

/// H5 pk popup 通用按钮（对齐 van-button round + gradient/solid color 两种风格）。
struct PKPopupButton: View {
    enum Style {
        case solidPurple           // H5 color="#6400D1"
        case gradientPurpleToRed   // H5 color="linear-gradient(90deg, #8515FF 0%, #E40132 100%)"
    }
    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    Capsule().fill(fill)
                }
                .contentShape(Capsule())
        }
    }

    /// 走 AnyShapeStyle 桥接以支持 SolidColor / LinearGradient 两种回填
    private var fill: AnyShapeStyle {
        switch style {
        case .solidPurple:
            return AnyShapeStyle(Color(hex: 0x6400D1))
        case .gradientPurpleToRed:
            return AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x8515FF),
                                                         Color(hex: 0xE40132)],
                                                startPoint: .leading, endPoint: .trailing))
        }
    }
}

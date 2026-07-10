import SwiftUI

/// PK 邀请时长设置独立 sheet（对齐 H5 `pkDurationPicker.vue`）。
///
/// **H5 蓝本**：pkInitiatePopup 顶部 setting 图标 tap → 弹 wheel picker，4 选项（3/5/10/15 min），
/// 选中后 save 到 `pkStore.pkSettings.defaultDuration`。
///
/// **iOS 实现**：`.sheet` 半屏，4 个按钮列表 + current 选中态视觉高亮。tap 选项 → 调 store 更新 +
/// 关 sheet。用户如果要 wheel picker 视觉可后续加 native `Picker(.wheel)`，本 MVP 用 list 更 iOS 惯例。
struct PKDurationPickerSheet: View {
    @ObservedObject var store: PKStore
    @Binding var isPresented: Bool

    private let options: [(seconds: Int, label: String)] = [
        (180, L10n.PK.inviteDuration3),
        (300, L10n.PK.inviteDuration5),
        (600, L10n.PK.inviteDuration10),
        (900, L10n.PK.inviteDuration15),
    ]

    /// 显式 internal init：`private let options` 会让编译器把 memberwise init 降级为 private，
    /// 外部 view（PKInviteSheet）无法访问 → 显式提供 init 绕开
    init(store: PKStore, isPresented: Binding<Bool>) {
        self.store = store
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))
            optionList
        }
        .background(
            LinearGradient(colors: [Color(hex: 0x371F9F),
                                    Color(hex: 0x17063D)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var header: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
            } label: {
                Text(L10n.PK.matchingCancel)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(L10n.PK.durationPickerTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Spacer()

            // 视觉平衡占位，与左侧 Cancel 等宽
            Text(L10n.PK.matchingCancel)
                .font(.system(size: 15))
                .foregroundColor(.clear)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var optionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                Button {
                    store.defaultDuration = opt.seconds
                    withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
                } label: {
                    HStack {
                        Text(opt.label)
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                        Spacer()
                        if store.defaultDuration == opt.seconds {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color(hex: 0xFF1AA7))
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 20).padding(.vertical, 16)
                }
                .buttonStyle(.plain)

                if idx < options.count - 1 {
                    Divider().background(Color.white.opacity(0.08))
                        .padding(.leading, 20)
                }
            }
            Spacer(minLength: 20)
        }
    }
}

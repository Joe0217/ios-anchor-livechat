import SwiftUI

/// Props FAQ 规则页（M1 Step 1b · spec §4.7 · B5 决策）。
///
/// **对齐 H5** `views/liveRule/index.vue` line 83-183（type=2 分支）—— 静态富文本 Q&A 页，无 API 调用。
///
/// **文案**：M1 Step 1b 阶段硬编码英文（对齐 H5 en.json 1113-1128）；三语言 L10n 迁移在 Step 1b 后半段跟上。
struct PropsRulesView: View {

    var body: some View {
        content
            .navigationBarBackButtonHidden(true)
            .swipeToPopEnabled()
            .background(Color(hex: 0x0B0010).ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            navBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    qaBlock(q: "Q1", title: "What are Props?", answer: "1. Create any exclusive shape or image to distinguish yourself from the crowd.\n2. Stay tuned for exclusive VIP props coming in the future.")
                    qaBlock(q: "Q2", title: "How can I get Props?", answer: "1. Purchase from the store.\n2. More activities coming soon.")
                    qaBlock(q: "Q3", title: "How can I wear and remove Props?", answer: "1. Enter the \"My Props\" interface, click on any prop to wear it, and click again to remove it.\n2. Only one prop from each category can be worn at a time.\n3. The new prop worn will automatically replace the currently displayed prop.")
                    Divider()
                        .background(.white.opacity(0.2))
                        .padding(.vertical, 4)
                    Text("Notes:")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    noteLine("1. In the same live room, a user's seat can only be activated once within 5 minutes.")
                    noteLine("2. When purchasing the same prop repeatedly during its validity period, the validity period will be automatically extended (calculated from the purchase time).")
                    noteLine("3. More new products will be launched soon, so stay tuned.")
                }
                .padding(16)
            }
        }
    }

    // MARK: - Nav Bar

    @Environment(\.dismiss) private var dismiss

    @ViewBuilder private var navBar: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text("Props Q&A")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            Color.clear.frame(width: 32, height: 32)  // 右侧占位对称
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: - QA block

    @ViewBuilder private func qaBlock(q: String, title: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(q)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: 0xFFE600))
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(answer)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func noteLine(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PropsRulesView()
    }
    .preferredColorScheme(.dark)
}
#endif

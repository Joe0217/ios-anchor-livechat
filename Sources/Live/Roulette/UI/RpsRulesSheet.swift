import SwiftUI

/// 猜拳规则说明浮层，对齐 H5 `rpsRulesSheet.vue` 的居中 popup。
/// H5 当前入口由上层 `openRpsRules` 事件控制；本组件只负责展示和关闭。
struct RpsRulesSheet: View {
    @Binding var isPresented: Bool
    let config: RpsRulesConfig

    init(isPresented: Binding<Bool>, config: RpsRulesConfig = .default) {
        self._isPresented = isPresented
        self.config = config
    }

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)

                rulesCard
                    .padding(.horizontal, 24)
            }
            .transition(.opacity)
        }
    }

    private var rulesCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                Text(L10n.liveRoomRpsRulesTitle)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.liveRoomRpsRulesGotIt))
            }
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                ruleRow(String(format: L10n.liveRoomRpsRulesBestOfFormat, config.bestOf))
                priceRuleRow
                ruleRow(L10n.liveRoomRpsRulesTies)
                ruleRow(String(format: L10n.liveRoomRpsRulesMedalFormat, config.medalBase, config.medalCap))
                ruleRow(L10n.liveRoomRpsRulesRefund, drawsSeparator: false)
            }

            Button(action: dismiss) {
                Text(L10n.liveRoomRpsRulesGotIt)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 140)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .padding(.top, 18)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: 280)
        .background(
            LinearGradient(colors: [Color(hex: 0x2A0055), Color(hex: 0x1A0033)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: 0xFF00DE).opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }

    private func ruleRow(_ text: String, drawsSeparator: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("·")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            if drawsSeparator {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .overlay(
                        Rectangle()
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .foregroundColor(Color.white.opacity(0.08))
                    )
            }
        }
    }

    private var priceRuleRow: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("·")
            Text(String(format: L10n.liveRoomRpsRulesPerChallengeFormat, config.price))
                .fixedSize(horizontal: false, vertical: true)
            Image("diamondYellow")
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .foregroundColor(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private func dismiss() {
        withAnimation { isPresented = false }
    }
}

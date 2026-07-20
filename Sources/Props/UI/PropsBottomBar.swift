import SwiftUI

/// Props 主页底部条（M1 Step 1b · spec §4.1 bottom bar · 对齐 H5 `bottomBarVisible`）。
///
/// - 只在 **选中已拥有卡（isFromBag=1）** 时出现（H5 `chooseItem.isFromBag === 1`）
/// - wearStatus==1 → 显示 Unequip；否则显示 Equip
/// - Ops loading 期间按钮转圈 + disabled
struct PropsBottomBar: View {
    let selected: PropItem
    let isBusy: Bool
    let onTap: (PropEquipAction) -> Void

    private var action: PropEquipAction {
        selected.wearStatus == 1 ? .unequip : .equip
    }

    private var title: String {
        selected.wearStatus == 1 ? "Unequip" : "Equip"
    }

    var body: some View {
        Button(action: { onTap(action) }) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().progressViewStyle(.circular).tint(.white)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(
            Color(hex: 0x0B0010)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

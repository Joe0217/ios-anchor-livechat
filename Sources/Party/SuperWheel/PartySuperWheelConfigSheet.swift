import SwiftUI

/// 房主/房管从工具栏打开的开局面板。档位和玩法开关均由服务端配置决定。
///
/// 视觉对齐 H5 `super-wheel-config-panel.vue`：
/// - 75vh bottom sheet，背景切图 bg-config 铺满整个 sheet（bg-cover bg-top）
/// - 左上 help 26×26 / 右上 close 26×26 距顶 14pt（相对 sheet 容器）
/// - 控件区贴底：px-18 pt-16 pb-18；档位胶囊 h-40：数字 15pt 700 白 + 钻石 16×16
/// - 奖励说明 13pt 白 82%，行高 1.5；Open Wheel 圆角按钮 h-48 渐变 primary，字 17pt 700
struct PartySuperWheelConfigSheet: View {
    @ObservedObject var wheelStore: PartySuperWheelStore
    let roomId: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFee: Int?
    @State private var showsRules = false

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundImage
            controlColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            iconButton(asset: "superWinnerHelp", action: onHelp)
                .padding(.leading, 14)
                .padding(.top, 14)
        }
        .overlay(alignment: .topTrailing) {
            iconButton(asset: "superWinnerClose", action: onClose)
                .padding(.trailing, 14)
                .padding(.top, 14)
        }
        .overlay {
            if showsRules {
                PartySuperWheelRulesOverlay { showsRules = false }
            }
        }
        .task { await handleTask() }
        .onChange(of: wheelStore.entryFees) { fees in
            if selectedFee == nil || !fees.contains(selectedFee ?? 0) {
                selectedFee = fees.first
            }
        }
        .onChange(of: wheelStore.isConfigPresented) { visible in
            if !visible { dismiss() }
        }
    }

    /// 铺满整个 sheet 的 bg-config 切图（bg-cover bg-top）
    private var backgroundImage: some View {
        CDNAssetImage("superWinnerBgConfig")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.PartyRoom.superWheelEntryFees)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(.white)
                .padding(.bottom, 14)

            entryFeesRow
                .padding(.bottom, 20)

            Text(L10n.PartyRoom.superWheelRewardHint)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.82))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            openButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var entryFeesRow: some View {
        if wheelStore.entryFees.isEmpty {
            Text(L10n.PartyRoom.superWheelLoading)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.5))
                .padding(.vertical, 10)
        } else {
            HStack(spacing: 12) {
                ForEach(wheelStore.entryFees, id: \.self) { fee in
                    feeChip(fee: fee)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func feeChip(fee: Int) -> some View {
        let selected = selectedFee == fee
        return Button(action: { selectedFee = fee }) {
            HStack(spacing: 6) {
                Text("\(fee)")
                    .environment(\.layoutDirection, .leftToRight)
                CDNAssetImage("giftPanelBalanceCoin")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            .font(.system(size: 15, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(feeChipBackground(selected: selected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func feeChipBackground(selected: Bool) -> some View {
        if selected {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.Palette.partyCreateModeTabA,
                            Theme.Palette.partyCreateModeTabB,
                            Theme.Palette.partyCreateModeTabC,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        } else {
            Capsule().fill(Color.white.opacity(0.08))
        }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            openButtonLabel
        }
        .buttonStyle(.plain)
        .disabled(openDisabled)
    }

    private var openButtonLabel: some View {
        Group {
            if wheelStore.isPerformingAction {
                ProgressView().tint(.white)
            } else {
                Text(L10n.PartyRoom.superWheelOpen)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            Capsule().fill(
                openDisabled
                ? AnyShapeStyle(Color.white.opacity(0.16))
                : AnyShapeStyle(
                    LinearGradient(
                        colors: [
                            Theme.Palette.partyCreateModeTabA,
                            Theme.Palette.partyCreateModeTabB,
                            Theme.Palette.partyCreateModeTabC,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
        )
    }

    private var openDisabled: Bool {
        selectedFee == nil || !wheelStore.isEnabled || wheelStore.isPerformingAction
    }

    private func iconButton(asset: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CDNAssetImage(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func handleTask() async {
        await wheelStore.prepareConfig()
        if selectedFee == nil {
            selectedFee = wheelStore.entryFees.first
        }
    }

    private func onClose() {
        dismiss()
    }

    private func onHelp() {
        showsRules = true
    }

    private func onOpen() {
        guard let fee = selectedFee, !roomId.isEmpty else { return }
        Task { await wheelStore.open(roomId: roomId, entryFee: fee) }
    }
}

import SwiftUI

/// 转盘奖项编辑子 sheet（对齐 H5 [liveRoulettePopup.vue L346-391] interactionPopup）
///
/// **交互**：
/// - 顶部标题 "Set Interaction Items"
/// - 已选列表 bubble（紫底 + 右上删除图标）
/// - 输入框（20 字上限 + 计数）—— 仅 draftSectors.count < 8 时显示
/// - 预设推荐横滑（已选/未选样式 toggle）
/// - 底部 Confirm 按钮（对齐 H5 saveBtn）
struct RouletteEditSheet: View {
    @ObservedObject var store: RouletteStore
    @Binding var isPresented: Bool

    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    private let maxInputLength = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(hex: 0x242221).ignoresSafeArea())
    }

    private var header: some View {
        Text(L10n.liveRoomRouletteEditTitle)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.top, 20).padding(.bottom, 20)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // 已选列表
                    ForEach(Array(store.draftSectors.enumerated()), id: \.element.id) { idx, sector in
                        selectedRow(sector: sector, index: idx)
                    }

                    // 输入框（<8 项时显示）
                    if store.draftSectors.count < 8 {
                        inputRow.padding(.top, 2)
                    }

                    // 预设推荐横滑（<8 项时显示）
                    if store.draftSectors.count < 8 && !store.presetItems.isEmpty {
                        presetRow.padding(.top, 12)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }

            confirmButton
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
    }

    private func selectedRow(sector: RouletteSector, index: Int) -> some View {
        HStack {
            Text(sector.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Button {
                store.removeSector(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color(hex: 0x7F6A9F), in: Capsule())
    }

    private var inputRow: some View {
        ZStack(alignment: .trailing) {
            HStack {
                TextField("", text: $inputText,
                          prompt: Text(L10n.liveRoomRouletteEditEnterItems)
                            .foregroundColor(.white.opacity(0.3)))
                    .foregroundColor(.white)
                    .focused($inputFocused)
                    .submitLabel(.done)
                    .onSubmit { commitInput() }
                    .onChange(of: inputText) { newValue in
                        // 20 字截断（对齐 H5 maxlength=20）
                        if newValue.count > maxInputLength {
                            inputText = String(newValue.prefix(maxInputLength))
                        }
                    }
                    .padding(.leading, 12).padding(.trailing, 50).padding(.vertical, 10)
                Spacer(minLength: 0)
            }
            Text("\(inputText.count)/\(maxInputLength)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
                .padding(.trailing, 12)
        }
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22))
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.presetItems) { preset in
                    let isSelected = store.draftSectors.contains { $0.presetId == preset.id }
                    Button {
                        store.togglePreset(preset)
                    } label: {
                        Text(preset.text)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(isSelected ? Color(hex: 0x7F6A9F) : Color.white.opacity(0.1),
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var confirmButton: some View {
        Button {
            inputFocused = false
            commitInputIfNeeded()
            Task {
                await store.confirmEdit()
                isPresented = false
            }
        } label: {
            Text(L10n.liveRoomRouletteEditConfirm)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(colors: [Color(hex: 0x8E60E6), Color(hex: 0xD074E9)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func commitInput() {
        guard !inputText.isEmpty else { return }
        store.appendManualSector(text: inputText)
        inputText = ""
    }

    /// Confirm 前若输入框还有未提交内容，先入队再走 save（对齐 H5 handleBlur 语义）
    private func commitInputIfNeeded() {
        if !inputText.isEmpty { commitInput() }
    }
}

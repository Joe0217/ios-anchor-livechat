import SwiftUI

/// 私 call 礼物选择 sheet（B-spec-开播设置页 v5）。
///
/// 对齐 H5 `views/liveSetting/index.vue` 的 `GiftsPopup`（type='CALL', selectCount=false）：
/// - 单选礼物
/// - 价格约束：`giftPrice >= minPrice`（H5 `liveCallGiftLimit.min = 4999` 硬编码，iOS 沿用）
/// - Confirm 传出选中的 gift；Cancel 保持原值
///
/// 实现原则：sheet 生命周期短，用 `@State` 而非独立 Store。
struct GiftPickerSheet: View {
    let minPrice: Int64
    let initialSelection: GiftListData?
    let onConfirm: (GiftListData?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var giftList: [GiftListData] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var selectedId: Int64?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    /// 展示列表 = 原始 - 低于 minPrice 的礼物（对齐 H5 语义：不达标礼物直接不展示，不做灰态）
    private var visibleGifts: [GiftListData] {
        giftList.filter { $0.giftPrice >= minPrice }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.screenBackground.ignoresSafeArea()
                content
            }
            .navigationTitle(L10n.giftPickerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.giftPickerCancel) { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.giftPickerConfirm) {
                        let sel = giftList.first { $0.id == selectedId }
                        onConfirm(sel)
                        dismiss()
                    }
                    .foregroundStyle(.pink)
                    .disabled(!canConfirm)
                }
            }
        }
        .task { await load() }
        .onAppear { selectedId = initialSelection?.id }
        .preferredColorScheme(.dark)
    }

    private var canConfirm: Bool {
        selectedId != nil && visibleGifts.contains(where: { $0.id == selectedId })
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().tint(.white).scaleEffect(1.2)
        } else if let errorMsg {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(errorMsg).font(.footnote).foregroundStyle(.white.opacity(0.8))
                Button(L10n.giftPickerRetry) {
                    Task { await load() }
                }
                .foregroundStyle(.pink)
            }
        } else if visibleGifts.isEmpty {
            Text(L10n.giftPickerEmpty).font(.footnote).foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(visibleGifts) { gift in
                        giftCell(gift)
                    }
                }
                .padding(16)
            }
        }
    }

    private func giftCell(_ gift: GiftListData) -> some View {
        let selected = selectedId == gift.id
        return VStack(spacing: 6) {
            AsyncImage(url: URL(string: gift.giftSmallImg.isEmpty ? gift.giftImg : gift.giftSmallImg)) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: 56, height: 56)

            Text(gift.name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)

            HStack(spacing: 3) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                Text("\(gift.giftPrice)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.pink.opacity(0.18) : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.pink : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedId = (selectedId == gift.id) ? nil : gift.id
        }
    }

    private func load() async {
        isLoading = true
        errorMsg = nil
        do {
            giftList = try await GiftService.getGiftList()
            isLoading = false
        } catch let e as APIError {
            errorMsg = String(format: L10n.livePrepareErrorPrefix, e.message, e.code)
            isLoading = false
        } catch {
            errorMsg = String(format: L10n.livePrepareErrorGeneric, error.localizedDescription)
            isLoading = false
        }
    }
}

import SwiftUI

/// Wishlist 心愿礼物选择 sheet（L-spec §4）—— 与 GiftPickerSheet 分叉：
/// - **单选礼物 + 每次选择带 数量**（1-99，对齐 H5 GiftsPopup selectCount=true）
/// - 无价格下限过滤（心愿单不像私 call 4999 硬限；只是 H5 描述文字"min 1200"，非 UI 校验）
///
/// Sheet 单次流程：tap 礼物 → 选中态 → 底部 count stepper 出现 → tap Confirm → 回传 (gift, count)
struct WishGiftPickerSheet: View {
    let onConfirm: (GiftListData, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var giftList: [GiftListData] = []
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var selectedId: Int64?
    @State private var count: Int = 1

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.screenBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    content
                    if selectedId != nil { countBar }
                }
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
                        if let sid = selectedId, let g = giftList.first(where: { $0.id == sid }) {
                            onConfirm(g, count)
                        }
                        dismiss()
                    }
                    .foregroundStyle(.pink)
                    .disabled(selectedId == nil)
                }
            }
        }
        .task { await load() }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            ProgressView().tint(.white).scaleEffect(1.2)
            Spacer()
        } else if let errorMsg {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow)
                Text(errorMsg).font(.footnote).foregroundStyle(.white.opacity(0.8))
                Button(L10n.giftPickerRetry) { Task { await load() } }
                    .foregroundStyle(.pink)
            }
            Spacer()
        } else if giftList.isEmpty {
            Spacer()
            Text(L10n.giftPickerEmpty).font(.footnote).foregroundStyle(.white.opacity(0.5))
            Spacer()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(giftList) { gift in giftCell(gift) }
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

            Text(gift.name).font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(1)

            HStack(spacing: 3) {
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(.yellow)
                Text("\(gift.giftPrice)").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.pink.opacity(0.18) : Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.pink : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectedId == gift.id { selectedId = nil }
            else { selectedId = gift.id; count = 1 }
        }
    }

    /// 底部 count stepper（选中礼物后出现）
    private var countBar: some View {
        HStack(spacing: 12) {
            Text(L10n.wishSettingGiftCount).font(.footnote).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button {
                if count > 1 { count -= 1 }
            } label: {
                Image(systemName: "minus.circle.fill").font(.title3).foregroundStyle(count > 1 ? .pink : .white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(count <= 1)

            Text("\(count)").font(.headline).foregroundStyle(.white).frame(minWidth: 30)

            Button {
                if count < 99 { count += 1 }
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(count < 99 ? .pink : .white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(count >= 99)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.black.opacity(0.6))
    }

    private func load() async {
        isLoading = true
        errorMsg = nil
        do {
            // 对齐 H5 `wishSetting/index.vue:679` <GiftsPopup type="LIVE">。
            // 曾误传 .wish 后端 code=1001 parameter.error —— 追 H5 源码证实心愿单实际用 LIVE scene
            giftList = try await GiftService.getGiftList(scene: .live)
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

import SwiftUI

/// 礼物选择器 sheet（H5 giftsPopup.vue 简化版）。
///
/// 拉一次礼物列表 → 3 列网格 → tap 一项即绑定 + dismiss；用户 close 未选 = 取消（触发 Store cancelGiftBinding）。
struct GiftMessagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: GiftMessageServiceProtocol
    /// 选中回调（Store 处理绑定）
    let onSelect: (GiftMessageItem) -> Void
    /// dismiss without selection 回调（Store 处理 pop 刚上传项）
    let onCancel: () -> Void

    @State private var gifts: [GiftMessageItem] = []
    @State private var loadState: LoadState = .idle
    @State private var didSelect: Bool = false

    private enum LoadState: Equatable {
        case idle, loading, loaded, error(String)
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color(hex: 0x1F1830).ignoresSafeArea())
                .navigationTitle(L10n.GiftMessage.giftPickerTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color(hex: 0x1F1830), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundColor(.white)
                        }
                    }
                }
                .task {
                    guard loadState == .idle else { return }
                    await loadGifts()
                }
                .onDisappear {
                    // 未 select 直接 dismiss → 触发 cancel
                    if !didSelect { onCancel() }
                }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            grid
        case .error(let msg):
            errorState(msg)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                      alignment: .center, spacing: 16) {
                ForEach(gifts) { gift in
                    Button {
                        didSelect = true
                        onSelect(gift)
                        dismiss()
                    } label: {
                        giftCell(gift)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func giftCell(_ gift: GiftMessageItem) -> some View {
        VStack(spacing: 4) {
            Group {
                if let s = gift.iconUrl, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Image(systemName: "gift.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.5))
                        }
                    }
                } else {
                    Image(systemName: "gift.fill").font(.system(size: 24)).foregroundColor(.white.opacity(0.5))
                }
            }
            .frame(width: 50, height: 50)
            Text(gift.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text("\(gift.price)")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.yellow.opacity(0.8))
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
            Button {
                Task { await loadGifts() }
            } label: {
                Text(L10n.blocklistLoadErrorRetry)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadGifts() async {
        loadState = .loading
        do {
            let list = try await service.fetchGifts()
            gifts = list
            loadState = .loaded
        } catch let e as APIError {
            loadState = .error(e.message)
        } catch {
            loadState = .error(L10n.GiftMessage.giftPickerLoadFail)
        }
    }
}

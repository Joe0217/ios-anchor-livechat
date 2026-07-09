import SwiftUI

/// 主播规范页（对齐 H5 `src/views/settings/anchorPolicy/index.vue`）。
///
/// 内容：白底 + 全宽远程规范图（`AppConfig.anchorPolicyImageURL`）+ 支持双指缩放。
/// 走 CachedAsyncImage 持久缓存（`persistent: true`）——单张图较大，加缓存避免重复下载。
struct AnchorPolicyView: View {
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ScrollView([.vertical, .horizontal], showsIndicators: false) {
            CachedAsyncImage(
                url: URL(string: AppConfig.anchorPolicyImageURL),
                contentMode: .fit,
                persistent: true
            ) {
                ZStack {
                    Color.white
                    ProgressView().tint(.gray)
                }
                .frame(maxWidth: .infinity, minHeight: 400)
            }
            .scaleEffect(scale)
            .gesture(magnifyGesture)
        }
        .background(Color.white)
        .navigationTitle(L10n.settingsAnchorPolicy)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.white, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(lastScale * value, 1), 4)
            }
            .onEnded { _ in
                lastScale = scale
                if scale < 1.05 { withAnimation(.easeOut(duration: 0.2)) { scale = 1; lastScale = 1 } }
            }
    }
}

#if DEBUG
#Preview {
    NavigationStack { AnchorPolicyView() }
}
#endif

import SwiftUI

/// G 里程碑 spec §6 / M3-2：匹配中遮罩。
///
/// **铁律 §8**：半透明胶囊条不全屏盖，保留本端 CameraPreview 可见。
struct PKMatchingOverlay: View {
    @ObservedObject var store: PKStore

    var body: some View {
        if store.state == .matching {
            VStack(spacing: 16) {
                Spacer()
                HStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.PK.matchingTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(L10n.PK.matchingSubtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

                Button {
                    Task { await store.cancelMatch() }
                } label: {
                    Text(L10n.PK.matchingCancel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 10)
                        .background(.red.opacity(0.85), in: Capsule())
                }
                .padding(.bottom, 64)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
    }
}

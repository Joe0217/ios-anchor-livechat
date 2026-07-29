import SwiftUI

/// 无动画资源礼物飘窗层。通话场景居中呈现，直播和派对保留底部轻提示。
///
/// H5 蓝本 `giftFloatTips.vue`：图 + x数量，3s 自动消失。
/// 私聊场景不启用（Center.showMicroToast 已按 scene=.chat 过滤）。
///
/// 2026-07-10 E-4 修复：只订阅 MicroToastBridge，current 变化不再触发本层重算
/// 2026-07-10 E-6 修复：图片走项目 ImageCache 而非 AsyncImage，同 URL 命中内存缓存不重新下载
struct MicroToastLayer: View {
    @ObservedObject var bridge: GiftEffectMicroToastBridge

    var body: some View {
        Group {
            if let latest = bridge.toasts.last {
                if latest.sceneKey.scene == .call {
                    // H5 g-faceTime/giftFloatTips.vue：居中 120pt 礼物图 + 38pt 紫色数量。
                    HStack(spacing: 10) {
                        MicroToastIcon(urlString: latest.imgUrl)
                            .frame(width: 120, height: 120)
                        Text("× \(latest.count)")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundColor(Color(red: 0.58, green: 0.20, blue: 0.92))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .id(latest.id)
                } else {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            MicroToastIcon(urlString: latest.imgUrl)
                                .frame(width: 60, height: 60)
                            Text("×\(latest.count)")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(Color(red: 0.58, green: 0.20, blue: 0.92))
                        }
                        .padding(.bottom, 200)
                        .transition(.opacity)
                        .id(latest.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: bridge.toasts.last?.id)
    }
}

/// ImageCache 缓存版 icon：同 URL 从内存缓存瞬时命中（避免 AsyncImage 的 .id() 重建 → 重下载）
private struct MicroToastIcon: View {
    let urlString: String?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: urlString) {
            guard let s = urlString, let url = URL(string: s) else {
                image = nil
                return
            }
            // 同步命中路径：无闪烁；未命中走异步 fetch
            if let cached = ImageCache.shared.cached(for: url) {
                image = cached
                return
            }
            image = await ImageCache.shared.fetch(url)
        }
    }
}

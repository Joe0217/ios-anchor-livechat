import SwiftUI

/// 底部 3s 小飘窗层（1v1 通话 / 直播 / 派对房 无动画资源礼物的兜底提示）
///
/// H5 蓝本 `giftFloatTips.vue`：图 + x数量，3s 自动消失。
/// 私聊场景不启用（Center.showMicroToast 已按 scene=.chat 过滤）。
struct MicroToastLayer: View {
    let toasts: [MicroToastItem]

    var body: some View {
        VStack {
            Spacer()
            if let latest = toasts.last {
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: latest.imgUrl ?? "")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fit)
                        default:
                            Color.clear
                        }
                    }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: toasts.last?.id)
    }
}

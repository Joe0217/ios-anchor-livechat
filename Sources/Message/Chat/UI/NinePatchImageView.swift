import SwiftUI
import UIKit
import Combine

/// H-3 SwiftUI 点九图气泡背景（spec §1.6 / §4.10）。
///
/// **对齐 H5** `msgItem.vue:220-221` + `app.less:1022-1036` `chat-bubble-custom`：
/// ```css
/// border-image-slice: 63 87 63 87 fill;
/// border-image-width: 32px 44px;
/// border-image-repeat: stretch;
/// ```
///
/// **iOS 等价**：`UIImage.resizableImage(withCapInsets: .init(top:63, left:87, bottom:63, right:87), resizingMode: .stretch)`
///
/// **使用**：
/// ```swift
/// NinePatchImageView(url: msg.chatBubble, capInsets: .init(top: 63, left: 87, bottom: 63, right: 87))
///     .overlay(alignment: .center) { Text(text).padding(.horizontal, 24).padding(.vertical, 14) }
/// ```
///
/// **下载失败兜底**（spec §R-25）：view 层用 `.overlay` fallback；本组件加载失败时 render 透明 background，
/// caller 需要在此之上叠 fallback（如 `RoundedRectangle` 默认圆角气泡）。
struct NinePatchImageView: UIViewRepresentable {
    let url: URL?
    let capInsets: UIEdgeInsets

    init(url: URL?, capInsets: UIEdgeInsets = .init(top: 63, left: 87, bottom: 63, right: 87)) {
        self.url = url
        self.capInsets = capInsets
    }

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleToFill
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        context.coordinator.setImage(on: view, url: url, capInsets: capInsets)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var cancellable: AnyCancellable?
        private var currentURL: URL?

        func setImage(on view: UIImageView, url: URL?, capInsets: UIEdgeInsets) {
            guard url != currentURL else { return }
            currentURL = url

            guard let url else {
                view.image = nil
                return
            }

            cancellable?.cancel()
            cancellable = URLSession.shared.dataTaskPublisher(for: url)
                .map { UIImage(data: $0.data) }
                .replaceError(with: nil)
                .receive(on: DispatchQueue.main)
                .sink { [weak view] img in
                    guard let img else {
                        view?.image = nil
                        return
                    }
                    view?.image = img.resizableImage(withCapInsets: capInsets, resizingMode: .stretch)
                }
        }
    }
}

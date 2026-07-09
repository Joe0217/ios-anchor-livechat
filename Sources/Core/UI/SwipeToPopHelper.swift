import SwiftUI
import UIKit

/// H-3 恢复 SwiftUI NavigationStack 内左滑返回手势（spec §1.6 / §4.12 / §F-57~59）。
///
/// **iOS 通用坑**：`.navigationBarBackButtonHidden(true)` 会**同时禁用**
/// `UINavigationController.interactivePopGestureRecognizer`（从左边缘右滑 pop）—— 因为系统 delegate
/// 默认判 nav bar 隐藏时拒绝手势。修法：把 delegate 设 nil + isEnabled 强制 true 双保险。
///
/// **使用**：
/// ```swift
/// var body: some View {
///     ...
///     .navigationBarBackButtonHidden(true)
///     .toolbar(.hidden, for: .navigationBar)      // iOS 16+
///     .swipeToPopEnabled()                         // 恢复手势
/// }
/// ```
///
/// **rule**：`swiftui-navbar-hidden-pop-gesture.md`（Step 6 retrospective 沉淀）
struct SwipeToPopHelper: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = ProbeVC()
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    /// 内部 vc：viewDidAppear 时挂到 parent nav controller，修复手势
    private final class ProbeVC: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // 上溯到最近的 UINavigationController（SwiftUI NavigationStack 底层桥 UINavigationController）
            var current: UIViewController? = self
            while let vc = current {
                if let nav = vc.navigationController {
                    nav.interactivePopGestureRecognizer?.delegate = nil
                    nav.interactivePopGestureRecognizer?.isEnabled = true
                    return
                }
                current = vc.parent
            }
        }
    }
}

extension View {
    /// H-3 spec §4.12：恢复 iOS 系统标准左边缘右滑返回手势
    func swipeToPopEnabled() -> some View {
        self.background(SwipeToPopHelper().frame(width: 0, height: 0))
    }
}

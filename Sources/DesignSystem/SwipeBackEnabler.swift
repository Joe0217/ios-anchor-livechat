import SwiftUI
import UIKit

/// 让 NavigationStack 子页在使用 `.navigationBarBackButtonHidden(true)` + 自定义 leading 时
/// 仍保留左滑返回手势（interactivePopGestureRecognizer）。
///
/// SwiftUI iOS 16+ NavigationStack 底层仍是 UINavigationController；隐藏系统 back button 时
/// SwiftUI 默认禁用左滑 pop。本 hack 通过 UIViewControllerRepresentable 找到所属
/// UINavigationController 并设 `interactivePopGestureRecognizer.delegate = nil` 强制启用。
///
/// 用法：
/// ```
/// MyDetailView()
///     .navigationBarBackButtonHidden(true)
///     .enableSwipeBack()
/// ```
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        SwipeBackHelperController()
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    /// 持有原 delegate + targetNav，view willDisappear 时还原（review 2026-06-25 建议-1）。
    /// 避免修改持久化在 nav 实例上影响未来其他子页。
    private final class SwipeBackHelperController: UIViewController {
        private weak var targetNav: UINavigationController?
        private weak var originalDelegate: UIGestureRecognizerDelegate?
        private var originalEnabled: Bool = true

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in
                self?.findAndEnableSwipeBack()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // 还原原状态，避免污染留给后续子页
            if let nav = targetNav {
                nav.interactivePopGestureRecognizer?.delegate = originalDelegate
                nav.interactivePopGestureRecognizer?.isEnabled = originalEnabled
            }
        }

        private func findAndEnableSwipeBack() {
            var current: UIViewController? = self
            while let vc = current {
                let nav: UINavigationController? = (vc as? UINavigationController) ?? vc.navigationController
                if let nav = nav {
                    // 保存原状态以便 disappear 时还原
                    self.targetNav = nav
                    self.originalDelegate = nav.interactivePopGestureRecognizer?.delegate
                    self.originalEnabled = nav.interactivePopGestureRecognizer?.isEnabled ?? true
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
    /// 启用左滑返回手势（配合 `.navigationBarBackButtonHidden(true)` 使用）。
    func enableSwipeBack() -> some View {
        background(SwipeBackEnabler())
    }
}

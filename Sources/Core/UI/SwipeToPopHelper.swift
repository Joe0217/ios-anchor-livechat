import SwiftUI
import UIKit

/// H-3 恢复 SwiftUI NavigationStack 内左滑返回手势（spec §1.6 / §4.12 / §F-57~59）。
///
/// **iOS 通用坑**：`.navigationBarBackButtonHidden(true)` 会**同时禁用**
/// `UINavigationController.interactivePopGestureRecognizer`（从左边缘右滑 pop）—— 因为系统 delegate
/// 默认判 nav bar 隐藏时拒绝手势。此 helper 可按页面需要显式开启或关闭，并在离开页面时恢复原状态。
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
    let isEnabled: Bool
    /// `nil` 保留普通页面原有的系统手势实现；仅 H5 容器传入闭包以按 history 决定是否 pop。
    var shouldAllowPop: (() -> Bool)? = nil

    func makeUIViewController(context: Context) -> UIViewController {
        ProbeVC(isEnabled: isEnabled, shouldAllowPop: shouldAllowPop)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? ProbeVC)?.setSwipeToPopEnabled(isEnabled, shouldAllowPop: shouldAllowPop)
    }

    /// 内部 vc：挂到最近的 NavigationStack 宿主，且离开时恢复此前页面的手势状态。
    private final class ProbeVC: UIViewController, UIGestureRecognizerDelegate {
        private var isSwipeToPopEnabled: Bool
        private var shouldAllowPop: (() -> Bool)?
        private weak var targetNavigationController: UINavigationController?
        private weak var originalGestureDelegate: UIGestureRecognizerDelegate?
        private var originalGestureEnabled = true
        private var hasSavedGestureState = false

        init(isEnabled: Bool, shouldAllowPop: (() -> Bool)?) {
            isSwipeToPopEnabled = isEnabled
            self.shouldAllowPop = shouldAllowPop
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in
                self?.applyGestureState()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyGestureState()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreGestureState()
        }

        func setSwipeToPopEnabled(_ isEnabled: Bool, shouldAllowPop: (() -> Bool)?) {
            self.shouldAllowPop = shouldAllowPop
            guard isSwipeToPopEnabled != isEnabled else { return }
            isSwipeToPopEnabled = isEnabled
            applyGestureState()
        }

        private func applyGestureState() {
            // 上溯到最近的 UINavigationController（SwiftUI NavigationStack 底层桥 UINavigationController）。
            var current: UIViewController? = self
            while let vc = current {
                if let nav = vc.navigationController {
                    configureGesture(in: nav)
                    return
                }
                current = vc.parent
            }
        }

        private func configureGesture(in navigationController: UINavigationController) {
            if let targetNavigationController,
               targetNavigationController !== navigationController {
                restoreGestureState()
            }

            guard let gesture = navigationController.interactivePopGestureRecognizer else { return }
            if !hasSavedGestureState {
                targetNavigationController = navigationController
                originalGestureDelegate = gesture.delegate
                originalGestureEnabled = gesture.isEnabled
                hasSavedGestureState = true
            }

            if isSwipeToPopEnabled {
                // 普通 SwiftUI 页面继续采用项目原有的 delegate=nil 方式恢复系统 pop。
                // H5 页面才需要手势代理按 Web history 决定该由谁处理左边缘滑动。
                gesture.delegate = shouldAllowPop == nil ? nil : self
                gesture.isEnabled = true
            } else {
                gesture.isEnabled = false
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === targetNavigationController?.interactivePopGestureRecognizer else {
                return true
            }
            return shouldAllowPop?() ?? true
        }

        private func restoreGestureState() {
            guard hasSavedGestureState else { return }
            if let gesture = targetNavigationController?.interactivePopGestureRecognizer {
                gesture.delegate = originalGestureDelegate
                gesture.isEnabled = originalGestureEnabled
            }
            targetNavigationController = nil
            originalGestureDelegate = nil
            hasSavedGestureState = false
        }
    }
}

extension View {
    /// H-3 spec §4.12：恢复 iOS 系统标准左边缘右滑返回手势
    func swipeToPopEnabled() -> some View {
        background(SwipeToPopHelper(isEnabled: true).frame(width: 0, height: 0))
    }

    /// 禁止原生 NavigationStack 从左边缘右滑 pop；业务层可自行接管该手势。
    func swipeToPopDisabled() -> some View {
        background(SwipeToPopHelper(isEnabled: false).frame(width: 0, height: 0))
    }

    /// 供滚动页在离开顶部时显式恢复系统导航栏的磨砂材质。
    /// 全局 scroll-edge 外观是透明的，单靠 SwiftUI toolbar modifier 在部分 NavigationStack
    /// 层级下不会覆盖该外观，因此使用 UIKit 直接配置当前导航控制器。
    func scrollingNavigationBarBlur(isVisible: Bool) -> some View {
        background(NavigationBarBlurAppearance(isVisible: isVisible).frame(width: 0, height: 0))
    }
}

private struct NavigationBarBlurAppearance: UIViewControllerRepresentable {
    let isVisible: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        ProbeViewController(isVisible: isVisible)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? ProbeViewController)?.setVisible(isVisible)
    }

    private final class ProbeViewController: UIViewController {
        private var isVisible: Bool
        private weak var navigationControllerTarget: UINavigationController?
        private var savedStandardAppearance: UINavigationBarAppearance?
        private var savedScrollEdgeAppearance: UINavigationBarAppearance?
        private var savedCompactAppearance: UINavigationBarAppearance?
        private var savedCompactScrollEdgeAppearance: UINavigationBarAppearance?

        init(isVisible: Bool) {
            self.isVisible = isVisible
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) {
            nil
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in
                self?.applyAppearance()
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyAppearance()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            restoreAppearance()
        }

        func setVisible(_ isVisible: Bool) {
            guard self.isVisible != isVisible else { return }
            self.isVisible = isVisible
            applyAppearance()
        }

        private func applyAppearance() {
            guard let navigationController = findNavigationController() else { return }
            if navigationControllerTarget !== navigationController {
                restoreAppearance()
                navigationControllerTarget = navigationController
                saveAppearance(from: navigationController.navigationBar)
            }
            let appearance = makeAppearance()
            let navigationBar = navigationController.navigationBar
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
            navigationBar.compactScrollEdgeAppearance = appearance
        }

        private func findNavigationController() -> UINavigationController? {
            var current: UIViewController? = self
            while let viewController = current {
                if let navigationController = viewController.navigationController {
                    return navigationController
                }
                current = viewController.parent
            }
            return nil
        }

        private func saveAppearance(from navigationBar: UINavigationBar) {
            savedStandardAppearance = navigationBar.standardAppearance.copy() as? UINavigationBarAppearance
            savedScrollEdgeAppearance = navigationBar.scrollEdgeAppearance?.copy() as? UINavigationBarAppearance
            savedCompactAppearance = navigationBar.compactAppearance?.copy() as? UINavigationBarAppearance
            savedCompactScrollEdgeAppearance = navigationBar.compactScrollEdgeAppearance?.copy() as? UINavigationBarAppearance
        }

        private func restoreAppearance() {
            guard let navigationController = navigationControllerTarget else { return }
            let navigationBar = navigationController.navigationBar
            if let savedStandardAppearance { navigationBar.standardAppearance = savedStandardAppearance }
            navigationBar.scrollEdgeAppearance = savedScrollEdgeAppearance
            navigationBar.compactAppearance = savedCompactAppearance
            navigationBar.compactScrollEdgeAppearance = savedCompactScrollEdgeAppearance
            navigationControllerTarget = nil
            savedStandardAppearance = nil
            savedScrollEdgeAppearance = nil
            savedCompactAppearance = nil
            savedCompactScrollEdgeAppearance = nil
        }

        private func makeAppearance() -> UINavigationBarAppearance {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.shadowColor = .clear
            guard isVisible else { return appearance }
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            appearance.backgroundColor = UIColor.white.withAlphaComponent(0.20)
            return appearance
        }
    }
}

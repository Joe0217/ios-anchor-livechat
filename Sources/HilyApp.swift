import SwiftUI
import Foundation
import UIKit

@main
struct HilyApp: App {
    @StateObject private var session = SessionStore.shared

    init() {
        // 全局 URLCache：内存 50MB + 磁盘 500MB。
        // 与 ImageCache（NSCache 内存层）协同：URLCache 给 URLSession 用，远端图片切 tab / 跨启动都不重下。
        // 磁盘 500MB：iOS 内建 LRU 淘汰，跨启动持久化 —— 治用户"每次看完都要重新加载"痛点。
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 500 * 1024 * 1024
        )

        Self.configureNavigationBarAppearance()
    }

    // 全局隐藏系统 back 按钮文案（保留箭头 + 滑动返回手势）。
    // 用透明色让 title 不可见；同步覆盖 standard/compact/scrollEdge 三态。
    private static func configureNavigationBarAppearance() {
        let backItem = UIBarButtonItemAppearance()
        let hidden: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]
        backItem.normal.titleTextAttributes = hidden
        backItem.highlighted.titleTextAttributes = hidden
        backItem.disabled.titleTextAttributes = hidden
        backItem.focused.titleTextAttributes = hidden

        let apply: (UINavigationBarAppearance) -> Void = { a in
            a.backButtonAppearance = backItem
        }

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        apply(standard)

        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        apply(scrollEdge)

        let compact = UINavigationBarAppearance()
        compact.configureWithDefaultBackground()
        apply(compact)

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = standard
        bar.scrollEdgeAppearance = scrollEdge
        bar.compactAppearance = compact
        bar.compactScrollEdgeAppearance = scrollEdge
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}

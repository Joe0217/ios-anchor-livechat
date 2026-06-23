import SwiftUI
import Foundation

@main
struct HilyApp: App {
    @StateObject private var session = SessionStore.shared

    init() {
        // 全局 URLCache：内存 20MB + 磁盘 100MB。
        // 与 ImageCache（NSCache 内存层）协同：URLCache 给 URLSession 用，
        // 远端图片切 tab 再回来不重新下载。
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 100 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}

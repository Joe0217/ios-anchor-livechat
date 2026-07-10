import SwiftUI
import AVKit
import Combine
import UIKit
import os

/// 图片/视频预览统一 LRU 缓存——公共组件，跨业务场景（朋友圈、头像预览、相册等）共享。
///
/// **约束**：
/// - 唯一硬上限：**总字节 ≤ 20MB**，不区分视频/图片数量
/// - 视频 buffer 按 15MB 固定估算；图片按 `cgImage.width × height × 4`（RGBA 解码内存）算
/// - LRU 淘汰：超上限时踢最旧 entry（视频、图片一视同仁）
/// - **缓存生命周期由 caller 控制**：容器 view（如 `CircleView`）在业务边界（tab 切走等）调 `clear()`；
///   `MediaGalleryView.onDisappear` 内**不 clear**，让用户"关闭预览再打开秒开"
/// - 内存告警自动 `clear()`（`UIApplication.didReceiveMemoryWarningNotification`）
///
/// **视频释放 = pause + `replaceCurrentItem(with: nil)`**：单 pause 不停下载，
/// `replaceCurrentItem(nil)` 才显式中断 AVAssetResourceLoader。
///
/// 单例 + `@MainActor`——AVPlayer / UIImage 跨 actor 访问 UB。
@MainActor
final class MediaGalleryCache {
    static let shared = MediaGalleryCache()

    /// A5：内存告警监听 —— 系统内存吃紧时先给低内存告警，App 主动释放非关键缓存优于被系统 kill。
    /// singleton 常驻不会 deinit，observer 无泄漏风险；仍在 deinit 移除以维持 API 契约。
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        // I1（P2-5）：singleton 常驻永不 nil，[weak self] 无实际意义——直接 shared 访问更清晰。
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                MediaGalleryCache.shared.clear()
            }
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private enum Entry {
        case video(AVPlayer)
        case image(UIImage, byteSize: Int)
    }

    /// URL → entry
    private var entries: [String: Entry] = [:]
    /// LRU：末尾最新，首元素最旧
    private var lru: [String] = []

    /// 唯一硬上限（用户约束）
    private let maxTotalBytes = 20 * 1024 * 1024
    /// 视频 buffer 估算权重——无 API 精确读取实时 buffer，15MB 覆盖短视频典型 buffer + decoder
    private let videoByteEstimate = 15 * 1024 * 1024

    // MARK: - Video

    func getVideo(url: String) -> AVPlayer? {
        guard case .video(let p) = entries[url] else { return nil }
        touch(url)
        return p
    }

    func putVideo(url: String, player: AVPlayer) {
        // 同 url 若已有旧 player 且是不同实例，释放旧的
        if let existing = entries[url], case .video(let oldP) = existing, oldP !== player {
            releasePlayer(oldP)
        }
        entries[url] = .video(player)
        touch(url)
        enforceByteLimit()
    }

    // MARK: - Image

    func getImage(url: String) -> UIImage? {
        guard case .image(let img, _) = entries[url] else { return nil }
        touch(url)
        return img
    }

    func putImage(url: String, image: UIImage) {
        // A4（P2-6）：对齐 putVideo 释放模式——若同 URL 旧 entry 是 video，显式释放 AVPlayer
        // 内 loader（pause + replaceCurrentItem(nil)），否则纯覆盖会让旧 AVPlayer 继续跑网络。
        // 当前 MomentPost.isVideo 按扩展名区分同 URL 类型稳定，本分支实际不触发；作为公共组件的 defensive 加固。
        if let existing = entries[url], case .video(let oldP) = existing {
            releasePlayer(oldP)
        }
        entries[url] = .image(image, byteSize: estimatedByteSize(of: image))
        touch(url)
        enforceByteLimit()
    }

    /// 显式驱逐单个视频——用于 `.failed` 状态的 player retry 前清池，避免复用重现同错。
    func evictVideo(url: String) {
        if let entry = entries.removeValue(forKey: url), case .video(let p) = entry {
            releasePlayer(p)
        }
        lru.removeAll { $0 == url }
    }

    // MARK: - Cleanup

    /// 清空所有缓存——视频 `replaceCurrentItem(nil)` 中断 loader
    func clear() {
        for (_, entry) in entries {
            if case .video(let p) = entry {
                releasePlayer(p)
            }
        }
        entries.removeAll()
        lru.removeAll()
    }

    // MARK: - Internal

    private func touch(_ url: String) {
        lru.removeAll { $0 == url }
        lru.append(url)
    }

    /// 超字节上限时按 LRU 踢最旧（视频、图片一视同仁）
    private func enforceByteLimit() {
        while totalCurrentBytes() > maxTotalBytes, !lru.isEmpty {
            let oldestUrl = lru.removeFirst()
            if let entry = entries.removeValue(forKey: oldestUrl) {
                if case .video(let p) = entry {
                    releasePlayer(p)
                }
            }
        }
    }

    private func totalCurrentBytes() -> Int {
        entries.values.reduce(0) { sum, entry in
            switch entry {
            case .video: return sum + videoByteEstimate
            case .image(_, let size): return sum + size
            }
        }
    }

    /// RGBA 解码内存估算——UIImage 展示时 iOS 解码为 32-bit 位图
    private func estimatedByteSize(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.width * cg.height * 4
        }
        let w = Int(image.size.width * image.scale)
        let h = Int(image.size.height * image.scale)
        return w * h * 4
    }

    /// 显式释放 AVPlayer——`replaceCurrentItem(nil)` 中断内部 loader 网络请求，
    /// 单纯 `pause()` 不会停止 buffer 下载。
    private func releasePlayer(_ p: AVPlayer) {
        p.pause()
        p.replaceCurrentItem(with: nil)
    }
}

/// 媒体图库预览的展示上下文（用于 `.fullScreenCover(item:)` 挂载）。
///
/// **调用方约束**：`.fullScreenCover` 必须挂在 **单一容器层**，不能在 `TabView(.page)` / `ForEach`
/// 内的多个 tag 各自挂——否则触发 SwiftUI presentation 竞态（`"Attempt to present while
/// a presentation is in progress"` 报错 + first-tap self-dismiss）。子 view 用 callback 向上传值
/// 触发容器 state 即可。
///
/// **命名避开 `MediaPreviewContext`**：Profile 已有一个 fileprivate 同名（asset+isVideo）。
struct MediaGalleryContext: Identifiable, Equatable {
    /// 图片/视频 URL 列表（自动按扩展名区分：`.mp4/.mov/...` 走视频播放器）
    let urls: [String]
    /// 起始展示索引（从 0 起）
    let startIndex: Int
    var id: String { "\(startIndex)-\(urls.first ?? "")" }
}

/// 媒体图库全屏预览——**公共组件**，用于图片/视频列表大图预览。
///
/// **使用方式**：
/// ```swift
/// @State private var galleryCtx: MediaGalleryContext?
///
/// SomeView()
///     .fullScreenCover(item: $galleryCtx) { ctx in
///         MediaGalleryView(urls: ctx.urls, startIndex: ctx.startIndex)
///     }
/// ```
///
/// **能力**：
/// - 全屏黑底 + 顶部关闭按钮
/// - 多图横滑（TabView.page，含页码指示）
/// - 图片/视频走 [`MediaGalleryCache`](x-source-tag://MediaGalleryCache) 统一 20MB LRU 池
/// - 图片外区域点击 / 下拉 > 100pt / 右上 X / VoiceOver escape 手势 关闭
/// - 视频保留系统 controls + loading spinner + `.failed` 错误占位 + retry
///
/// **调用方缓存生命周期职责**：
/// - `MediaGalleryView` 自身不 clear pool（关闭再开秒开）
/// - 容器 view（如 CircleView）需在业务边界调 `MediaGalleryCache.shared.clear()`（例：tab 切走）
///
/// **参考实现**：朋友圈预览 [CircleView](x-source-tag://CircleView)（点朋友圈九宫格 → 拉起本 view）。
struct MediaGalleryView: View {
    /// 数据源：远端 URL 列表 or 本地 UIImage 列表（发布页选图预览用）。
    /// 两种模式共享 TabView 横滑 + 页码 + 下拉关闭 + a11y；仅 cell 加载路径不同。
    fileprivate enum Source {
        case urls([String])
        case localImages([UIImage])

        var count: Int {
            switch self {
            case .urls(let arr): return arr.count
            case .localImages(let arr): return arr.count
            }
        }

        func isVideo(at index: Int) -> Bool {
            if case .urls(let arr) = self, arr.indices.contains(index) {
                return MomentPost.isVideo(url: arr[index])
            }
            return false
        }
    }

    fileprivate let source: Source
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    /// 下拉关闭的 drag 偏移（视觉跟手 + 松手判定）
    @State private var dragOffsetY: CGFloat = 0

    /// 远端 URL 列表模式（默认）——图片/视频按扩展名自动分派
    init(urls: [String], startIndex: Int = 0) {
        self.source = .urls(urls)
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    /// 本地 UIImage 列表模式（发布页选图预览用）
    /// - 不走网络、不入 MediaGalleryCache；随 view dismiss 释放
    init(localImages: [UIImage], startIndex: Int = 0) {
        self.source = .localImages(localImages)
        self.startIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(1 - Double(min(abs(dragOffsetY), 200)) / 400.0)
                .ignoresSafeArea()

            if source.count == 1 {
                singleContent(at: 0, isCurrent: true)
                    .offset(y: dragOffsetY)
            } else {
                TabView(selection: $currentIndex) {
                    ForEach(0..<source.count, id: \.self) { i in
                        singleContent(at: i, isCurrent: i == currentIndex)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))
                .offset(y: dragOffsetY)
            }

            // 顶部关闭按钮
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.title, design: .default))  // A2：semantic 支持 Dynamic Type
                            .foregroundStyle(.white, .black.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                    .accessibilityLabel(L10n.mediaPreviewClose)
                }
                Spacer()
            }
        }
        // 下拉手势关闭（vertical drag > 100pt 触发；只识别向下拖）
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffsetY = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > 100 {
                        dismiss()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffsetY = 0
                        }
                    }
                }
        )
        .statusBar(hidden: true)
        // A4：VoiceOver 用户执行不了 DragGesture，加系统 escape 手势（两指画 Z）作为逃生入口。
        // xmark 按钮仍在，此处作补充；对齐 iOS 惯例。
        .accessibilityAction(.escape) {
            dismiss()
        }
        // 注意：本处**不 clear pool**——用户诉求"关闭再开秒开"。
        // 清空由 CircleView 在 outer/home tab 切走时统一执行。
    }

    /// 单张内容：ZStack 最底 `Color.clear.onTapGesture { dismiss }` 接收"图片以外区域"tap。
    /// 图片本身不装 onTapGesture，tap 落在 image 时被 Image 消耗（不关闭）；
    /// 落在 aspectRatio(.fit) 收缩后的空白区域时，穿透到 Color.clear 触发 dismiss。
    /// 视频保留系统 controls，其上层 Color.clear 也在 controls 下层，不干扰播放。
    @ViewBuilder
    private func singleContent(at index: Int, isCurrent: Bool) -> some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    dismiss()
                }
            switch source {
            case .urls(let arr):
                if MomentPost.isVideo(url: arr[index]) {
                    MediaGalleryVideoPlayer(urlString: arr[index], isCurrent: isCurrent)
                } else {
                    MediaGalleryImageCell(urlString: arr[index])
                        .allowsHitTesting(true)
                }
            case .localImages(let arr):
                Image(uiImage: arr[index])
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(true)
            }
        }
        // A3（P2-3）：VoiceOver 感知媒体类型 + 页码——`.combine` 合并子元素为整体读，
        // 避免 VoiceOver 分开读"图像""视频播放器"默认 label 而无法感知内容。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(at: index))
    }

    /// A3：媒体位置 + 类型 a11y 文案（走 L10n 支持 i18n）
    private func accessibilityLabel(at index: Int) -> String {
        let typeLabel = source.isVideo(at: index) ? L10n.mediaPreviewVideo : L10n.mediaPreviewImage
        let position = String(format: L10n.mediaPreviewPositionFormat, currentIndex + 1, source.count)
        return "\(typeLabel) \(position)"
    }
}

/// 图片单元：走 `MediaGalleryCache` 图片桶，未命中时用 `ImageCache.fetchEphemeral` 下载。
///
/// **不走 CachedAsyncImage**：CachedAsyncImage 有 App 级 NSCache 语义，预览用会污染全局；
/// 这里用池独立管理，会话结束时 clear 释放，符合"20MB 上限 + 不跨会话"约束。
///
/// **三态视觉**（与视频侧的 loading/error 对齐）：
/// - `.loading` → ProgressView 白色转圈（不叠加）
/// - `.loaded(UIImage)` → 图片本体
/// - `.failed` → photo.slash 图标 + 文案 + retry；retry 重置为 loading 再走一次 load
///
/// `retryToken` 递增触发 `.task(id:)` 重跑，实现 "点击 retry → 重新拉图" 的正确取消 + 重启。
private struct MediaGalleryImageCell: View {
    let urlString: String

    private enum LoadState: Equatable {
        case loading
        case loaded(UIImage)
        case failed
    }
    @State private var state: LoadState = .loading
    @State private var retryToken: Int = 0

    var body: some View {
        ZStack {
            Color.black   // 底色：loading/failed 期避免透明区域
            switch state {
            case .loading:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failed:
                failedOverlay
            }
        }
        .task(id: TaskKey(url: urlString, retry: retryToken)) {
            await load()
        }
    }

    private var failedOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.slash")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.5))
            Text(L10n.mediaPreviewImageLoadFailed)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            Button {
                state = .loading
                retryToken &+= 1
            } label: {
                Text(L10n.mediaPreviewImageRetry)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// `.task(id:)` 用组合 key：url 变化或 retry 递增都触发重跑 + 取消旧任务
    private struct TaskKey: Equatable {
        let url: String
        let retry: Int
    }

    @MainActor
    private func load() async {
        // 池命中 → 直接展示（跳过 loading 闪烁）
        if let cached = MediaGalleryCache.shared.getImage(url: urlString) {
            state = .loaded(cached)
            return
        }
        // 未命中 → 保持 loading 直到结果回来
        guard let url = URL(string: urlString) else {
            state = .failed
            return
        }
        let fetched = await ImageCache.shared.fetchEphemeral(url)
        // I1：用 Task.isCancelled 而非同源派生比较——`.task(id:)` 在 key 变化时会取消旧 Task，
        // await 恢复后此处 isCancelled=true 即丢弃 stale 写入，避免快速滑动时错位图片。
        guard !Task.isCancelled else { return }
        if let fetched {
            MediaGalleryCache.shared.putImage(url: urlString, image: fetched)
            state = .loaded(fetched)
        } else {
            state = .failed
        }
    }
}

/// 视频播放：走 `MediaGalleryCache` 视频池，20MB 上限内保留 buffer 跨 tag / 跨会话秒开。
///
/// **修复历史**：
/// - v5.7-：每 tag 建 player + play → 多 player 并发卡顿 + `VKCImageAnalyzerRequest cancel`
/// - v5.8：仅 current 建 + 切走 nil 释放 → 卡顿修好，但每次切回重 loading
/// - v5.9：切走 pause 不 nil → 同会话跨 tag 秒开；跨会话仍重 loading
/// - v5.10a：会话级 pool + MediaGalleryView.onDisappear clear → 关闭再开重 loading（体验退化）
/// - **v5.10b（当前）**：pool 保留跨预览会话，仅 CircleView tab 切走时 clear；用户诉求 = "20MB 内保留一切"
///
/// **AVURLAsset 显式创建 + 异步 preload**：消除 `Main thread blocked by synchronous property query`
/// 警告——SwiftUI VideoPlayer 内部会同步查询 asset.isPlayable/duration，若 asset 未 loaded 就阻塞主线程。
/// `Task.detached` 预热让首次同步查询命中已缓存属性。
private struct MediaGalleryVideoPlayer: View {
    let urlString: String
    let isCurrent: Bool
    @State private var player: AVPlayer?
    @State private var isReady: Bool = false
    /// R2：AVPlayerItem `.failed` 时切错误占位（URL 404 / OSS token 过期 / CDN 挂 / 后端删视频）。
    @State private var loadError: Bool = false
    /// timeControlStatus 订阅（.playing / .waitingToPlayAtSpecifiedRate）
    @State private var statusCancellable: AnyCancellable?
    /// AVPlayerItem.status 订阅（.failed 检测）
    @State private var itemStatusCancellable: AnyCancellable?
    /// R1（P2-4）：AVURLAsset preload Task handle，用于 retry / dismount 时主动 cancel，
    /// 避免旧 asset.load 抛错晚于新加载成功到达 → loadError=true 覆盖已成功状态 → 闪错误占位。
    @State private var preloadTask: Task<Void, Never>?

    /// A1（P2-1）：AVAudioSession 配置失败时的日志（CarPlay/AirPlay 异常 / SDK 独占等场景）
    private static let audioLogger = Logger(subsystem: "com.anchor.livechat", category: "MediaGalleryAudio")

    /// R1：区分"view dismount"与"app 切后台"——ScenePhase=.background 时 onDisappear 也会触发。
    /// 见 [.claude/rules/swiftui-camera-preview.md](../../../.claude/rules/swiftui-camera-preview.md) §6。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
                    .allowsHitTesting(isCurrent)
            }

            // R2：加载失败错误占位（含 retry）
            if isCurrent && loadError {
                errorOverlay
            } else if isCurrent && !isReady {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.4)
            }
        }
        .task(id: urlString) {
            guard isCurrent else { return }
            attachPlayer()
        }
        .onChange(of: isCurrent) { newCurrent in
            if newCurrent {
                // R1 兜底：切回 tag 时若 observer 已断（切后台过 / 兼容将来 rule 变化），恢复 observer
                if player == nil {
                    attachPlayer()
                } else if statusCancellable == nil {
                    attachStatusObserver(to: player!)
                    player?.play()
                } else {
                    player?.play()
                }
            } else {
                player?.pause()
            }
        }
        // R1：app 切后台时 SwiftUI 也会触发 onDisappear（rule 6），此处守卫避免误清 observer
        .onDisappear {
            guard scenePhase != .background else { return }
            player?.pause()
            statusCancellable?.cancel()
            statusCancellable = nil
            itemStatusCancellable?.cancel()
            itemStatusCancellable = nil
            // R1（P2-4）：view 真正 dismount 时 cancel preload Task 释放 asset.load 网络请求
            preloadTask?.cancel()
            preloadTask = nil
        }
    }

    /// R2：错误占位视图 —— 图标 + 文案 + retry 按钮
    private var errorOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(.title, design: .default))  // A2：semantic 支持 Dynamic Type
                .foregroundStyle(.yellow.opacity(0.85))
            Text(L10n.circleMomentLoadError)
                .font(.callout)  // A2：semantic 支持 Dynamic Type
                .foregroundColor(.white.opacity(0.85))
            Button {
                retryLoad()
            } label: {
                Text(L10n.profileRetry)
                    .font(.callout.weight(.medium))  // A2：semantic 支持 Dynamic Type
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// R2：retry —— `.failed` 的 AVPlayerItem 不可恢复，必须驱逐 pool 里的 failed player 后重建
    @MainActor
    private func retryLoad() {
        MediaGalleryCache.shared.evictVideo(url: urlString)
        statusCancellable?.cancel()
        statusCancellable = nil
        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil
        // R1（P2-4）：cancel 旧 preload Task 避免其抛错晚到覆盖新成功状态
        preloadTask?.cancel()
        preloadTask = nil
        player = nil
        loadError = false
        isReady = false
        attachPlayer()
    }

    /// attach 优先查池——命中即复用（无 loading），未命中新建后入池
    @MainActor
    private func attachPlayer() {
        guard player == nil else { return }

        // A1：AVAudioSession .playback + .mixWithOthers
        // - .playback：静音键下也响（对齐微信朋友圈；纯 .soloAmbient 默认会被静音键静音）
        // - .mixWithOthers：不打断用户后台音乐（对齐 UGC 视频行业惯例）
        // 声网/云信 SDK 进直播/通话时会自设 .playAndRecord 覆盖，此处不需要显式恢复。
        //
        // A1（P2-1）：改 do/catch + Logger.error 便于线上排查——CarPlay/AirPlay 状态异常
        // / 系统被 SDK 独占时 setCategory 可能失败，配置失败视频无声但无用户可见错误，
        // 光靠 try? 吞错线上无法定位。
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.audioLogger.error("audio session setup failed: \(error.localizedDescription)")
        }

        if let cached = MediaGalleryCache.shared.getVideo(url: urlString) {
            attachStatusObserver(to: cached)
            player = cached
            cached.play()
            return
        }

        guard let url = URL(string: urlString) else { return }
        // 显式 AVURLAsset + 异步 preload 属性——消除主线程 sync query 警告
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // 限制 forward buffer 上限——pause 后 iOS 会尽快停止 buffer 填充，避免关闭预览后长时间跑流量
        item.preferredForwardBufferDuration = 30
        let p = AVPlayer(playerItem: item)
        attachStatusObserver(to: p)
        MediaGalleryCache.shared.putVideo(url: urlString, player: p)
        player = p
        // 异步 preload asset 常用属性——SwiftUI VideoPlayer 内部访问 isPlayable/duration 时若未 loaded 会主线程阻塞
        // R2 二次修正：**删除 asset.isPlayable == false 判定**。该同步属性在 load 完成后瞬间可能仍返
        // false（KVO 传播延迟 / HLS 需额外网络请求判定 playability），触发误报 loadError 但视频已成功播放。
        // 只依赖两条可靠信号：asset.load() 抛错 + item.status 变 .failed（在 attachStatusObserver 内）。
        //
        // R1（P2-4）：Task 存 handle 支持 cancel。retry / onDisappear 时主动 cancel + catch 内
        // Task.isCancelled 守卫，避免旧 Task 迟到抛错覆盖新成功状态。
        preloadTask?.cancel()
        preloadTask = Task { @MainActor in
            do {
                _ = try await asset.load(.isPlayable, .duration, .tracks)
            } catch {
                guard !Task.isCancelled else { return }
                loadError = true
            }
        }
        p.play()
    }

    /// 挂 status 监听——同时监听 timeControlStatus（loading spinner）+ item.status（`.failed` 错误占位）。
    ///
    /// **A6**：`.removeDuplicates()` 防弱网 buffer 抖动（.waitingToPlayAtSpecifiedRate ↔ .playing）
    /// 高频 publish 触发多余 body 重算。
    /// **I2**：sink 内 `Task { @MainActor in }` 包裹以兼容 Swift 6 strict 并发（@Sendable 闭包写 @State 需显式 hop）。
    @MainActor
    private func attachStatusObserver(to p: AVPlayer) {
        isReady = false
        loadError = false
        // timeControlStatus：.playing → 隐藏 spinner；.waitingToPlayAtSpecifiedRate → 显示 spinner
        statusCancellable = p.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { status in
                Task { @MainActor in
                    if status == .playing {
                        isReady = true
                    } else if status == .waitingToPlayAtSpecifiedRate {
                        isReady = false
                    }
                }
            }
        // R2：item.status .failed → 切错误占位。直接 subscribe item 的 status keyPath，
        // 而非嵌套 `\.currentItem?.status`（嵌套 optional KVO 语义不明）。
        // pool 内 player 都有 currentItem（我们从不 replaceCurrentItem(nil) 除非驱逐），此处安全。
        if let item = p.currentItem {
            itemStatusCancellable = item.publisher(for: \.status, options: [.initial, .new])
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { status in
                    Task { @MainActor in
                        if status == .failed {
                            loadError = true
                        }
                    }
                }
        }
    }
}

#if DEBUG
struct MediaGalleryView_Previews: PreviewProvider {
    static var previews: some View {
        MediaGalleryView(
            urls: [
                "https://picsum.photos/800/1200",
                "https://picsum.photos/1200/800",
                "https://example.com/video.mp4",
            ],
            startIndex: 0
        )
        .preferredColorScheme(.dark)
    }
}
#endif

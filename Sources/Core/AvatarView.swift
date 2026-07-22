import SwiftUI

/// 通用头像组件（对齐 H5 `c-avatar.vue` + `v-image.vue` 的 userImg 分流）。
///
/// - 主播 / 用户默认头像不同：`kind` 分流本地兜底图
///   - `.anchor` → `Image("defaultAvatar")`（H5 `assets/icon/head.png` 同源）
///   - `.user`   → `Image("defaultUserAvatar")`（H5 `robotCall/user-default-avatar.webp` 转 PNG）
/// - 支持头像框叠加（H 里程碑道具体系接入后传入 `headwearURL` 即可）
/// - 附送在线小圆点（`showsOnlineDot`），对齐 LiveListUserCard 用法
///
/// **内置 tap 分派**（传 `userId` 即启用）：
/// - 自己头像 / 无 userId / `disablesTap: true` → 不响应 tap
/// - 当前处于 Party 房 / 通话 / 直播中 → 弹名片卡（走 `\.avatarUserCardPresenter`）
/// - 其它环境 → 跳详情页（走 `\.avatarProfilePusher`）
/// - Environment 未挂载 → tap 无反应（fallback，不 crash）
///
/// 用法：
/// ```swift
/// // 详情/名片卡自动分派（推荐）
/// AvatarView(urlString: user.icon, size: 56, kind: .user, userId: String(user.userId))
///
/// // 外层已挂 tap/NavigationLink，opt-out
/// AvatarView(urlString: user.icon, size: 56, kind: .user, disablesTap: true)
/// ```
struct AvatarView: View {
    enum Kind {
        /// 主播头像（默认图 = H5 head.png）
        case anchor
        /// 用户头像（默认图 = H5 defaultPeople 同类图形）
        case user
    }

    let url: URL?
    let size: CGFloat
    var kind: Kind = .anchor
    /// 头像框图 URL（道具体系佩戴后返回）。为空不显示框。
    var headwearURL: URL? = nil
    /// 头像框相对头像的尺寸比。H5 rank 页示例 = 1.0（同尺寸叠加）；游戏化框通常 >1.0 外扩。
    var headwearRatio: CGFloat = 1.0
    /// 是否显示右下在线绿点（Live 列表用法）
    var showsOnlineDot: Bool = false
    /// 是否写入持久缓存。默认 true（用户切账号时由 SessionStore.logout → ImageCache.clear 兜底清理，
    /// 见 [session-scoped-store-refresh.md](../.claude/rules/session-scoped-store-refresh.md)）。
    /// **默认 true 的原因**：直播列表 / 消息列表 / 私聊气泡等场景，同一用户头像跨 view 高频复用，
    /// 若不持久化每次进入都会重新下载，是本工程主要流量与加载慢的根因。
    var persistent: Bool = true
    /// 头像所属用户 id（String 兼容后端 Int/String 混发）。传 nil = 不启用内置 tap 分派
    var userId: String? = nil
    /// 显式禁用内置 tap，用于外层已挂 tap/NavigationLink 的场景 opt-out
    var disablesTap: Bool = false

    @Environment(\.avatarUserCardPresenter) private var userCardPresenter
    @Environment(\.avatarProfilePusher) private var profilePusher
    /// 房间容器显式注入时优先使用，避免依赖全局 store 判断当前场景。
    @Environment(\.avatarTapEnvironmentOverride) private var tapEnvironmentOverride

    init(url: URL?,
         size: CGFloat,
         kind: Kind = .anchor,
         headwearURL: URL? = nil,
         headwearRatio: CGFloat = 1.0,
         showsOnlineDot: Bool = false,
         persistent: Bool = true,
         userId: String? = nil,
         disablesTap: Bool = false) {
        self.url = url
        self.size = size
        self.kind = kind
        self.headwearURL = headwearURL
        self.headwearRatio = headwearRatio
        self.showsOnlineDot = showsOnlineDot
        self.persistent = persistent
        self.userId = userId
        self.disablesTap = disablesTap
    }

    /// 字符串 URL 便捷入口（大部分接口返 String?）
    init(urlString: String?,
         size: CGFloat,
         kind: Kind = .anchor,
         headwearURL: String? = nil,
         headwearRatio: CGFloat = 1.0,
         showsOnlineDot: Bool = false,
         persistent: Bool = true,
         userId: String? = nil,
         disablesTap: Bool = false) {
        self.init(
            url: urlString.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            size: size,
            kind: kind,
            headwearURL: headwearURL.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            headwearRatio: headwearRatio,
            showsOnlineDot: showsOnlineDot,
            persistent: persistent,
            userId: userId,
            disablesTap: disablesTap
        )
    }

    var body: some View {
        // 用最大边界（头像 vs 头像框）作为整体外框，避免上层布局按 avatar 尺寸算错
        let outerSize = max(size, size * headwearRatio)

        Group {
            if enablesInlineTap {
                Button(action: handleTap) {
                    avatarStack(outerSize: outerSize)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            } else {
                avatarStack(outerSize: outerSize)
            }
        }
        .frame(width: outerSize, height: outerSize)
    }

    private func avatarStack(outerSize: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // 中心对齐的头像 + 头像框
            ZStack {
                avatarLayer
                    .frame(width: size, height: size)
                    .clipShape(Circle())

                if let headwearURL {
                    CachedAsyncImage(url: headwearURL, contentMode: .fit, persistent: true, cdn: (headwearCDNSize, .fit)) {
                        Color.clear
                    }
                    .frame(width: size * headwearRatio, height: size * headwearRatio)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: outerSize, height: outerSize)

            if showsOnlineDot {
                onlineDot
            }
        }
        .frame(width: outerSize, height: outerSize)
    }

    /// 是否启用内置 tap 分派：非 disable + 有 userId + 非自己
    private var enablesInlineTap: Bool {
        guard !disablesTap, let uid = userId, !uid.isEmpty else { return false }
        if let mine = SessionStore.shared.user?.userId, String(mine) == uid { return false }
        return true
    }

    @MainActor
    private func handleTap() {
        guard let uid = userId, !uid.isEmpty else { return }
        switch tapEnvironmentOverride ?? AvatarTapEnvironmentDetector.detect() {
        case .liveRoom, .partyRoom, .call:
            userCardPresenter?(uid)
        case .list:
            profilePusher?(uid)
        }
    }

    @ViewBuilder
    private var avatarLayer: some View {
        CachedAsyncImage(url: url, contentMode: .fill, persistent: persistent, cdn: (avatarCDNSize, .fill)) {
            defaultImage
        }
    }

    /// 按头像渲染尺寸自动选 CDN 档位（2 档：<72pt 小档、>=72pt 大档，最大化缓存命中率）
    private var avatarCDNSize: CDNImageSize {
        size < 72 ? .avatarSmall : .avatarLarge
    }

    /// 头饰按外框尺寸（size * headwearRatio）选档
    private var headwearCDNSize: CDNImageSize {
        (size * headwearRatio) < 72 ? .avatarSmall : .avatarLarge
    }

    @ViewBuilder
    private var defaultImage: some View {
        switch kind {
        case .anchor:
            Image("defaultAvatar")
                .resizable()
                .scaledToFill()
        case .user:
            Image("defaultUserAvatar")
                .resizable()
                .scaledToFill()
        }
    }

    /// 在线小圆点：尺寸按头像大小自适应（≈ size * 0.21,最小 8pt），描边同 LiveListUserCard 原样式
    private var onlineDot: some View {
        let dotSize = max(size * 0.21, 8)
        return Circle()
            .fill(Theme.Palette.liveListOnlineDot)
            .frame(width: dotSize, height: dotSize)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1.5))
            .padding(2)
    }
}

// MARK: - 环境自探（tap 时现场判定，不订阅 store）

/// 头像 tap 环境。tap 触发时现场判定，body 不订阅 store 避免 30+ view 频繁重算。
enum AvatarTapEnvironment {
    case liveRoom
    case partyRoom
    case call
    case list
}

@MainActor
enum AvatarTapEnvironmentDetector {
    /// 优先级：party > call > live > list
    /// 三态几乎不会重叠（业务上不能同时开播+通话+进 party），若并发以 party 兜底优先
    static func detect() -> AvatarTapEnvironment {
        if PartyStore.shared.roomState == .joined { return .partyRoom }
        if CallStore.shared.state != .idle && CallStore.shared.state != .ended { return .call }
        if LiveStore.shared.state == .living { return .liveRoom }
        return .list
    }
}

// MARK: - Environment 挂载点（caller 上层挂 presenter/pusher）

private struct AvatarUserCardPresenterKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

private struct AvatarProfilePusherKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

private struct AvatarTapEnvironmentOverrideKey: EnvironmentKey {
    static let defaultValue: AvatarTapEnvironment? = nil
}

extension EnvironmentValues {
    /// 头像 tap 弹名片卡的 presenter（LiveRoomView / PartyRoomView / CallView / ChatDetailView popup 挂）
    var avatarUserCardPresenter: ((String) -> Void)? {
        get { self[AvatarUserCardPresenterKey.self] }
        set { self[AvatarUserCardPresenterKey.self] = newValue }
    }
    /// 头像 tap 跳详情的 pusher（各 NavigationStack 根节点挂）
    var avatarProfilePusher: ((String) -> Void)? {
        get { self[AvatarProfilePusherKey.self] }
        set { self[AvatarProfilePusherKey.self] = newValue }
    }
    /// 当前容器的显式头像点击场景。仅房间容器需要设置。
    var avatarTapEnvironmentOverride: AvatarTapEnvironment? {
        get { self[AvatarTapEnvironmentOverrideKey.self] }
        set { self[AvatarTapEnvironmentOverrideKey.self] = newValue }
    }
}

extension View {
    /// 声明当前作用域内头像 tap 名片卡的 presenter（LiveRoomView / PartyRoomView / CallView 挂）
    func avatarUserCardPresenter(_ present: @escaping (String) -> Void) -> some View {
        environment(\.avatarUserCardPresenter, present)
    }
    /// 声明当前作用域内头像 tap 跳详情的 pusher（各 NavigationStack 根节点挂）
    func avatarProfilePusher(_ push: @escaping (String) -> Void) -> some View {
        environment(\.avatarProfilePusher, push)
    }
    /// 显式声明头像点击场景，避免容器使用非单例 store 时被全局状态误判。
    func avatarTapEnvironmentOverride(_ scene: AvatarTapEnvironment) -> some View {
        environment(\.avatarTapEnvironmentOverride, scene)
    }
}

import SwiftUI

/// 通用头像组件（对齐 H5 `c-avatar.vue` + `v-image.vue` 的 userImg 分流）。
///
/// - 主播 / 用户默认头像不同：`kind` 分流本地兜底图
///   - `.anchor` → `Image("defaultAvatar")`（H5 `assets/icon/head.png` 同源）
///   - `.user`   → `Image("defaultUserAvatar")`（H5 `robotCall/user-default-avatar.webp` 转 PNG）
/// - 支持头像框叠加（H 里程碑道具体系接入后传入 `headwearURL` 即可）
/// - 附送在线小圆点（`showsOnlineDot`），对齐 LiveListUserCard 用法
///
/// 用法：
/// ```swift
/// AvatarView(urlString: user.icon, size: 56, kind: .user, showsOnlineDot: true)
/// AvatarView(urlString: anchor.icon, size: 40, kind: .anchor, headwearURL: anchor.headwear)
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
    /// 是否写入持久缓存。默认 false（列表他人头像场景），本人头像等场景传 true
    var persistent: Bool = false

    init(url: URL?,
         size: CGFloat,
         kind: Kind = .anchor,
         headwearURL: URL? = nil,
         headwearRatio: CGFloat = 1.0,
         showsOnlineDot: Bool = false,
         persistent: Bool = false) {
        self.url = url
        self.size = size
        self.kind = kind
        self.headwearURL = headwearURL
        self.headwearRatio = headwearRatio
        self.showsOnlineDot = showsOnlineDot
        self.persistent = persistent
    }

    /// 字符串 URL 便捷入口（大部分接口返 String?）
    init(urlString: String?,
         size: CGFloat,
         kind: Kind = .anchor,
         headwearURL: String? = nil,
         headwearRatio: CGFloat = 1.0,
         showsOnlineDot: Bool = false,
         persistent: Bool = false) {
        self.init(
            url: urlString.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            size: size,
            kind: kind,
            headwearURL: headwearURL.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            headwearRatio: headwearRatio,
            showsOnlineDot: showsOnlineDot,
            persistent: persistent
        )
    }

    var body: some View {
        // 用最大边界（头像 vs 头像框）作为整体外框，避免上层布局按 avatar 尺寸算错
        let outerSize = max(size, size * headwearRatio)

        ZStack(alignment: .bottomTrailing) {
            // 中心对齐的头像 + 头像框
            ZStack {
                avatarLayer
                    .frame(width: size, height: size)
                    .clipShape(Circle())

                if let headwearURL {
                    CachedAsyncImage(url: headwearURL, contentMode: .fit, persistent: false, cdn: (headwearCDNSize, .fit)) {
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

    /// 在线小圆点：尺寸按头像大小自适应（≈ size * 0.21，最小 8pt），描边同 LiveListUserCard 原样式
    private var onlineDot: some View {
        let dotSize = max(size * 0.21, 8)
        return Circle()
            .fill(Theme.Palette.liveListOnlineDot)
            .frame(width: dotSize, height: dotSize)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 1.5))
            .padding(2)
    }
}

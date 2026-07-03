import SwiftUI

/// 朋友圈一条动态卡片：作者 + 时间 + 文本 + 图片网格 + 赞/评/删除操作行。
///
/// 三入口视觉差异由调用方注入 flag：
/// - `onLikeTap` 非 nil → 点赞按钮可点（me + moment 入口）
/// - `onDeleteTap` 非 nil → 显示删除按钮（仅 me 入口）
/// - `showComment` → 显示评论计数（me + moment 入口；official 隐藏）
struct MomentPostRow: View {
    let post: MomentPost
    /// 点赞回调（可选）。Circle Moment trial #1 注入 → 触发 `MomentFeedStore.tapLike`；
    /// Profile MomentTabView 只读不传，默认 nil 时 heart 不可点击。
    var onLikeTap: (() -> Void)? = nil
    /// 删除回调（仅 me 入口注入；对齐 H5 `circle/me.vue` showDelete=true）。
    var onDeleteTap: (() -> Void)? = nil
    /// 是否显示评论计数（official 入口为 false，对齐 H5 `circle/official.vue` showContent=false）。
    var showComment: Bool = true
    /// 图片/视频 cell 点击回调（父 view 拉起大图预览）。参数：`imgUrls` 中的 index。
    var onImageTap: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let text = post.textContent, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.92))
                    // 对齐 H5 `whitespace-pre-wrap break-all`，不截断
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let urls = post.imgUrls, !urls.isEmpty {
                imageGrid(urls: urls)
            }
            footer
            // 评论列表（对齐 H5 `circleContent.vue:229`：永久挂载，不受 showContent 控制；
            // 视口内 cell 出现时 .task 触发拉一次，无评论时 view 内部 v-if 不渲染，无空白）
            if let pid = post.postId {
                MomentCommentsSection(postId: pid)
            }
        }
        .padding(12)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Theme.Metric.profileDescPadding)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 动态作者头像：作为通用组件，按"他人头像"规则 persistent=false，不污染缓存。
            // 若实际就是登录账号自己的头像（"我的"动态 tab），NSCache 命中后仍能复用。
            AvatarView(urlString: post.icon, size: 36, kind: .anchor)

            VStack(alignment: .leading, spacing: 2) {
                // 对齐 H5 `font-500 text-16` 昵称字号
                Text(post.nickname ?? "—")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(Self.relativeTime(str: post.createTime))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    private func imageGrid(urls: [String]) -> some View {
        // 对齐 H5 `circle/components/list.vue`：统一 3 列 1:1 正方形 + 6px 间距。
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(urls.indices, id: \.self) { i in
                gridCell(url: urls[i], index: i)
            }
        }
    }

    /// 视频/图片分开渲染 + **硬约束正方形尺寸**（对齐 H5 `circleContent.vue`）。
    ///
    /// **尺寸约束策略**：外层 `Color.clear.aspectRatio(1, .fit)` 撑正方形骨架（Color 无
    /// intrinsic size 会严格遵守 aspectRatio），内部 `.overlay` 图片/视频再撑满 —— 比
    /// 直接给 `CachedAsyncImage.aspectRatio` 更稳。
    ///
    /// **点击预览**：用 `Button + buttonStyle(.plain)` 包裹而非 `.onTapGesture` —— footer 里的 delete
    /// Button（Me 入口）会 "snoop" 上下 view tree 的 `.onTapGesture` 导致 hit conflict；Button
    /// 天然优先级更明确且与其他 Button 兼容。同时保持视觉透明（.plain 不 tint）。
    @ViewBuilder
    private func gridCell(url: String, index: Int) -> some View {
        Button {
            onImageTap?(index)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)  // 骨架强制正方形（Color 无 intrinsic size，严格遵守）
                .overlay {
                    if MomentPost.isVideo(url: url) {
                        videoCellPlaceholder
                    } else {
                        CachedAsyncImage(url: URL(string: url), contentMode: .fill) {
                            Theme.Palette.profileGridPlaceholder
                        }
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 视频占位：黑底 + 播放图标。真缩略图 backlog（需 AVAssetImageGenerator）。
    private var videoCellPlaceholder: some View {
        ZStack {
            Color.black.opacity(0.55)
            Image(systemName: "play.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Spacer()
            // me 入口显示删除按钮（onDeleteTap 非 nil 时）
            if let onDeleteTap {
                Button {
                    onDeleteTap()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.momentActionDelete)
            }
            likeStatItem
            // official 入口隐藏评论计数（showComment=false）
            if showComment {
                statItem(icon: "bubble.left",
                         value: post.commentCount ?? 0,
                         tint: Color.white.opacity(0.55))
            }
        }
    }

    /// 点赞行：注入 onLikeTap 时包 Button，否则纯展示
    @ViewBuilder
    private var likeStatItem: some View {
        let icon = post.likeFlag == 1 ? "heart.fill" : "heart"
        let tint: Color = post.likeFlag == 1 ? .red : .white.opacity(0.55)
        let value = post.likeCount ?? 0

        if let onLikeTap {
            Button {
                onLikeTap()
            } label: {
                statItem(icon: icon, value: value, tint: tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(post.likeFlag == 1 ? L10n.momentActionUnlike : L10n.momentActionLike)
            .accessibilityValue("\(value)")
        } else {
            statItem(icon: icon, value: value, tint: tint)
        }
    }

    private func statItem(icon: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
        }
    }

    /// 把 createTime 字符串转成简单相对时间：刚刚 / Xm / Xh / Xd / 日期。
    ///
    /// trial step 3 真集成反悔：实测后端发的是字符串 (H5 type.ts:25 createTime: string)，
    /// 步 1a 写成 Int? 是 spec §1.4 第 3 项遗留 bug。
    /// 多种格式兜底：ISO8601 → "yyyy-MM-dd HH:mm:ss" (Asia/Shanghai 解析) → 原字符串。
    /// 完全本地计算，不引入第三方库。文案与日期格式走 L10n + 本地时区（展示）。
    private static func relativeTime(str: String?) -> String {
        guard let str, !str.isEmpty else { return "" }
        guard let then = parseDate(str) else {
            // 无法识别格式 — 直接返原字符串避免空白
            return str
        }
        let now = Date()
        let diff = max(0, now.timeIntervalSince(then))
        if diff < 60 { return L10n.momentRelativeJustNow }
        if diff < 3600 { return String(format: L10n.momentRelativeMinutesFormat, Int(diff / 60)) }
        if diff < 86400 { return String(format: L10n.momentRelativeHoursFormat, Int(diff / 3600)) }
        if diff < 86400 * 7 { return String(format: L10n.momentRelativeDaysFormat, Int(diff / 86400)) }
        return displayDayFormatter.string(from: then)
    }

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso8601Formatter.date(from: s) { return d }
        if let d = iso8601FormatterNoFrac.date(from: s) { return d }
        if let d = spacedFormatter.date(from: s) { return d }
        return nil
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601FormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "yyyy-MM-dd HH:mm:ss" 后端常见格式 (Asia/Shanghai 时区，CLAUDE.md 时区纪律)
    private static let spacedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// 展示用 day formatter（≥7 天的动态显示绝对日期）。
    /// 与 parse 用的 spacedFormatter 不同——parse 必须固定 Asia/Shanghai 以正确解析后端字符串；
    /// display 跟随用户本地时区与区域（ar/tr 区域获得本地日期格式 + 月份名）。
    private static let displayDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("yMMMd")
        f.timeZone = .current
        f.locale = .current
        return f
    }()
}

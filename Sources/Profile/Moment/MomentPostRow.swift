import SwiftUI

/// 朋友圈一条动态卡片：作者 + 时间 + 文本 + 图片九宫格 + 赞/评统计。
///
/// L14 阶段仅渲染，无点赞/评论/删除交互；L15-L16 接入操作。
struct MomentPostRow: View {
    let post: MomentPost
    /// 点赞回调（可选）。Cycle Moment trial #1 注入 → 触发 `MomentFeedStore.tapLike`；
    /// Profile MomentTabView 只读不传，默认 nil 时 heart 不可点击。
    var onLikeTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let text = post.textContent, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(8)
            }
            if let urls = post.imgUrls, !urls.isEmpty {
                imageGrid(urls: urls)
            }
            footer
        }
        .padding(12)
        .background(Theme.Palette.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Theme.Metric.profileDescPadding)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 动态作者头像：作为通用组件，按"他人头像"规则 persistent=false，不污染缓存。
            // 若实际就是登录账号自己的头像（"我的"动态 tab），NSCache 命中后仍能复用。
            CachedAsyncImage(url: URL(string: post.icon ?? ""), contentMode: .fill, persistent: false) {
                Color.gray.opacity(0.3)
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(post.nickname ?? "—")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text(Self.relativeTime(str: post.createTime))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer()
        }
    }

    private func imageGrid(urls: [String]) -> some View {
        // 1 张：大图；2-4 张：2×2；5+：3 列
        let columnCount: Int = urls.count == 1 ? 1 : (urls.count <= 4 ? 2 : 3)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount)

        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(urls.indices, id: \.self) { i in
                CachedAsyncImage(url: URL(string: urls[i]), contentMode: .fill) {
                    Theme.Palette.profileGridPlaceholder
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Spacer()
            likeStatItem
            statItem(icon: "bubble.left",
                     value: post.commentCount ?? 0,
                     tint: Color.white.opacity(0.55))
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

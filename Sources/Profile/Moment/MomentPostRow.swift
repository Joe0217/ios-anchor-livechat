import SwiftUI

/// 朋友圈一条动态卡片：作者 + 时间 + 文本 + 图片九宫格 + 赞/评统计。
///
/// L14 阶段仅渲染，无点赞/评论/删除交互；L15-L16 接入操作。
struct MomentPostRow: View {
    let post: MomentPost

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
                Text(Self.relativeTime(ms: post.createTime))
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
            statItem(icon: post.likeFlag == 1 ? "heart.fill" : "heart",
                     value: post.likeCount ?? 0,
                     tint: post.likeFlag == 1 ? Color.red : Color.white.opacity(0.55))
            statItem(icon: "bubble.left",
                     value: post.commentCount ?? 0,
                     tint: Color.white.opacity(0.55))
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

    /// 把毫秒时间戳转成简单相对时间："Just now" / "Xm" / "Xh" / "Xd" / 日期。
    /// 完全本地计算，不引入第三方库。
    private static func relativeTime(ms: Int?) -> String {
        guard let ms, ms > 0 else { return "" }
        let now = Date()
        let then = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let diff = max(0, now.timeIntervalSince(then))
        if diff < 60 { return "Just now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        if diff < 86400 * 7 { return "\(Int(diff / 86400))d" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: then)
    }
}

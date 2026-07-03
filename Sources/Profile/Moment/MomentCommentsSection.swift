import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "MomentCommentsSection")

/// 每条 post 底部的评论列表（对齐 H5 `circle/components/comments.vue`）。
///
/// **行为**（严格对齐 H5）：
/// - 视口进入前 600px 提前触发拉评论（H5 IntersectionObserver + rootMargin 600px）
///   → iOS 用 LazyVStack + `.task` 天然实现（cell 出现在视口内时 mount + task 触发）
/// - **仅触发一次**（H5 `stop()` 语义）：内部 loaded flag 守
/// - 拉最近 7 天，pageSize 100
/// - 空评论时**不渲染任何 UI**（H5 `v-if="comments.length"`），卡片不留空白
/// - 展示：`nickname:` (紫色) + `commentContent` 单行截断
struct MomentCommentsSection: View {

    let postId: Int
    /// 服务注入（默认 CircleService.shared；单测/Preview 可传 mock）
    var service: CircleServiceProtocol = CircleService.shared

    @State private var comments: [MomentComment] = []
    @State private var loaded: Bool = false

    var body: some View {
        Group {
            if !comments.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(comments) { c in
                        commentLine(c)
                    }
                }
                .padding(10)
                .background(Theme.Palette.momentCommentsBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task {
            await loadOnce()
        }
    }

    @ViewBuilder
    private func commentLine(_ c: MomentComment) -> some View {
        HStack(spacing: 4) {
            Text("\(c.nickname ?? "—"):")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Palette.momentCommentNickname)
                .lineLimit(1)
                .layoutPriority(1)  // 昵称优先不被截断
            Text(c.commentContent ?? "")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
    }

    private func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        do {
            let res = try await service.getComments(postId: postId, pageSize: 100, currentPage: 1)
            comments = res
        } catch {
            logger.warning("getComments postId=\(postId) failed: \(String(describing: error))")
            // 静默失败：评论加载失败不打扰用户（对齐 H5 无错误 UI）
        }
    }
}

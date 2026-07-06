import SwiftUI

/// L 里程碑 Match tab：顶部跑马灯胶囊。
///
/// 视觉/交互对齐 [LiveNoticeBar](../../Components/LiveNoticeBar.swift)（首页礼物跑马灯）：
/// - 垂直 slide 转场：新条从下方滑入 + 旧条向顶部滑出（H5 c-marquee vertical Swiper）
/// - `.task(id:)` 驱动循环（非 Timer.publish），感知 keep-alive `isActive`
/// - `.id(currentIndex)` 单调递增触发 transition（避免 record 内容重复时 SwiftUI 不切）
/// - 外层 `clipShape` 兜住 slide 不溢出边界
///
/// 空 callList 时用 demo fallback（对齐 H5 主播端语义：跑马灯一直显示）。
struct MatchMarqueeView: View {
    let records: [MatchCallRecord]
    /// keep-alive 架构下感知 Match tab 是否真可见，不可见时 task 立即 return，能耗归零。
    var isActive: Bool = true

    @State private var currentIndex: Int = 0

    private struct LoopKey: Hashable {
        let count: Int
        let active: Bool
    }

    var body: some View {
        // 真数据优先；空 records 时用 demo 序列（3 条循环，让切换效果可见）
        let list = effectiveRecords
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.matchMarquee, style: .continuous)
                .fill(Theme.Gradients.matchMarqueeBg)

            singleRow(list[safeIndex(in: list)])
                .padding(.horizontal, Theme.Metric.matchMarqueeHPadding)
        }
        .frame(height: Theme.Metric.matchMarqueeHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.matchMarquee, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.matchMarquee, style: .continuous)
                .strokeBorder(Theme.Gradients.matchMarqueeBorder, lineWidth: 1)
        )
        .padding(.horizontal, Theme.Metric.matchMarqueeHMargin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yText(list[safeIndex(in: list)]))
        .task(id: LoopKey(count: list.count, active: isActive)) {
            guard isActive, list.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.4)) {
                    currentIndex = (currentIndex + 1) % max(list.count, 1)
                }
            }
        }
    }

    // MARK: - 内容

    private func singleRow(_ record: MatchCallRecord) -> some View {
        HStack(spacing: 6) {
            AvatarView(urlString: record.callerIcon,
                       size: Theme.Metric.matchMarqueeAvatarSize,
                       kind: .user)
            Image("matchMarqueeCallIcon")
                .resizable()
                .scaledToFit()
                .frame(width: Theme.Metric.matchMarqueeCallIconWidth,
                       height: Theme.Metric.matchMarqueeCallIconHeight)
                .accessibilityHidden(true)
            AvatarView(urlString: record.receiverIcon,
                       size: Theme.Metric.matchMarqueeAvatarSize,
                       kind: .user)

            // caller（黄）→ receiver（绿）: Video Call Started.
            // iOS 16 兼容：禁 Text `+` 拼接，用 `\(...)` 插值 + Text helper
            Text("\(caller(record))\(arrow)\(receiver(record))\(colon)\(callStarted)")
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 6)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 用 currentIndex 而非 record.id 做 view identity——对齐 LiveNoticeBar：
        // record 内容可能重复（同 caller/receiver 昵称）导致 SwiftUI 视为同 view 不 transition
        .id(currentIndex)
        // 垂直 slide：新条底部滑入 / 旧条顶部滑出（对齐 H5 c-marquee vertical Swiper）
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
    }

    // MARK: - Text 片段 helper（避免 `+` 拼接触发 iOS 16 编译器 type-check 超时）

    private func caller(_ r: MatchCallRecord) -> Text {
        Text(r.callerNickname).foregroundColor(Theme.Palette.matchMarqueeReceiver)
    }
    /// 使用 SF Symbol `arrow.forward` —— 系统自动随 layoutDirection 镜像
    /// （ar RTL 布局时字形反转为「←」，视觉方向与文本流一致）；对齐 CLAUDE.md
    /// 「布局用语义化方向 leading/trailing」的精神扩展到方向符号。
    private var arrow: Text {
        Text(" \(Image(systemName: "arrow.forward")) ")
            .foregroundColor(Theme.Palette.matchMarqueeText)
    }
    private func receiver(_ r: MatchCallRecord) -> Text {
        Text(r.receiverNickname).foregroundColor(Theme.Palette.matchMarqueeCaller)
    }
    private var colon: Text {
        Text(": ").foregroundColor(Theme.Palette.matchMarqueeText)
    }
    private var callStarted: Text {
        Text(L10n.matchMarqueeCallStarted).foregroundColor(Theme.Palette.matchMarqueeText)
    }

    // MARK: - 数据 / index

    /// 真数据优先，空 records 时用 demo 序列（3 条循环切换）
    private var effectiveRecords: [MatchCallRecord] {
        records.isEmpty ? Self.demoRecords : records
    }

    /// 真接口尚未返回 / dev 环境后端无数据时的兜底 demo（3 条循环，让切换效果可见）
    private static let demoRecords: [MatchCallRecord] = [
        MatchCallRecord(callerIcon: "", callerNickname: "James",
                        receiverIcon: "", receiverNickname: "Emma"),
        MatchCallRecord(callerIcon: "", callerNickname: "Alice",
                        receiverIcon: "", receiverNickname: "Bob"),
        MatchCallRecord(callerIcon: "", callerNickname: "Oliver",
                        receiverIcon: "", receiverNickname: "Sophia"),
    ]

    /// 归一化索引——list 变更时 currentIndex 可能瞬时越界
    private func safeIndex(in list: [MatchCallRecord]) -> Int {
        guard !list.isEmpty else { return 0 }
        return currentIndex % list.count
    }

    /// VoiceOver 语义化文案：用 L10n format "%@ called %@" 替代 "→" 箭头符号（RTL 无歧义）
    private func a11yText(_ record: MatchCallRecord) -> String {
        L10n.matchMarqueeA11yCallFormat(caller: record.callerNickname,
                                        receiver: record.receiverNickname)
    }
}

#Preview {
    VStack(spacing: 12) {
        MatchMarqueeView(records: [
            MatchCallRecord(callerIcon: "", callerNickname: "James",
                            receiverIcon: "", receiverNickname: "Emma"),
            MatchCallRecord(callerIcon: "", callerNickname: "Alice",
                            receiverIcon: "", receiverNickname: "Bob"),
        ])
        // 空态走 demo fallback
        MatchMarqueeView(records: [])
        Spacer()
    }
    .padding(.top, 40)
    .background(Theme.Palette.screenBackground)
    .preferredColorScheme(.dark)
}

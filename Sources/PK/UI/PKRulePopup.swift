import SwiftUI
import UIKit

/// PK 规则弹窗（对齐 H5 `pkRulePopup.vue`）。
///
/// **呈现方式**：`.fullScreenCover` 挂在 PKInviteSheet 内部——SwiftUI fullScreenCover 会**盖过** `.sheet` 层级，
/// 加上 [ClearFullScreenCoverBackground] workaround 让 fullScreenCover 背景透明，
/// 露出半透黑蒙层 + 中央卡片视觉，实现"居中弹窗"效果。
///
/// **UI**（2026-07-11 用户明示简化）：
/// - **无 title**，**无右上角关闭 X**——只保留底部紫红渐变 OK 按钮
/// - 中央卡片 **95% 屏宽**，圆角 20，紫色渐变 `#5300A1 → #3800A0`
/// - 内容：远端规则图（`PKService.selectPKRuleIcon`）+ ScrollView 允许长图滚动
/// - 高度上限：内容区 ≤ 65% 屏高，总高度不超 80%（用户明示上限）
struct PKRulePopup: View {
    @Binding var isPresented: Bool

    enum LoadState: Equatable {
        case loading
        case loaded(url: String)
        case empty
        case failed
    }

    @State private var state: LoadState = .loading

    init(isPresented: Binding<Bool>) {
        self._isPresented = isPresented
    }

    var body: some View {
        // v22（2026-07-11）：加 isPresented gate —— 让 PKRulePopup 可安全嵌入 overlay 而非仅 fullScreenCover
        // （原实现 body 无 gate → PKInvitedSheet.overlay 挂载时永远显示且关不掉）
        if isPresented {
            ZStack {
                // 半透黑蒙层（拦截 tap 但不允许点击关闭——只走 OK 按钮）
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())

                // 中央卡片：95% 屏宽 · 无 title · 无 X · 底部 OK 按钮
                centerCard
            }
            // 让 fullScreenCover 背景透明，露出底下 PKInviteSheet 视觉（overlay 挂载时无影响）
            .background(ClearFullScreenCoverBackground())
            .task { await load() }
        }
    }

    // MARK: - Center card

    /// 中央卡片宽度：95% 屏宽（用户明示）
    private var cardWidth: CGFloat {
        UIScreen.main.bounds.width * 0.95
    }

    /// 内容区高度上限：屏高 65%（+ OK 按钮 + padding 总 ≤ 80%）
    private var contentMaxHeight: CGFloat {
        UIScreen.main.bounds.height * 0.65
    }

    private var centerCard: some View {
        VStack(spacing: 20) {
            contentArea
            confirmButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(width: cardWidth)
        .background(
            LinearGradient(colors: [Color(hex: 0x5300A1),
                                    Color(hex: 0x3800A0)],
                           startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Content area 4 态

    @ViewBuilder
    private var contentArea: some View {
        switch state {
        case .loading:
            loadingView
        case .loaded(let url):
            ruleImageScroll(url: url)
        case .empty:
            emptyView
        case .failed:
            failedView
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer(minLength: 60)
            ProgressView().tint(.white)
            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func ruleImageScroll(url: String) -> some View {
        ScrollView {
            CachedAsyncImage(url: URL(string: url), contentMode: .fit, persistent: true) {
                Color.clear.frame(height: 160)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: contentMaxHeight)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.3))
            Text(L10n.PK.rankSheetEmpty)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var failedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange.opacity(0.8))
            Text(L10n.liveRoomContributionErrorRetry)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.7))
            Button(action: { Task { await load() } }) {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    /// 底部 OK 按钮（唯一关闭入口，对齐 H5 pkRulePopup.vue L130-144 紫红渐变）
    private var confirmButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isPresented = false }
        } label: {
            Text(L10n.PK.resultConfirm)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    LinearGradient(colors: [Color(hex: 0x8515FF),
                                            Color(hex: 0xE40132)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        state = .loading
        do {
            let url = try await PKService.selectPKRuleIcon()
            state = url.isEmpty ? .empty : .loaded(url: url)
        } catch {
            state = .failed
        }
    }
}

// MARK: - fullScreenCover 背景透明 helper

/// SwiftUI 的 `.fullScreenCover` 默认背景不透明会遮盖底下视图。
/// 通过 UIViewRepresentable 拿到 hosting controller 的 view 层，把 backgroundColor 设为 `.clear`，
/// 让 fullScreenCover 只保留内容层（半透黑蒙层 + 中央卡片），底下的 PKInviteSheet 视觉透过来。
private struct ClearFullScreenCoverBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { [weak view] in
            // UITransitionView → UIViewController.view chain：向上追 superview 到 hostingController view
            var v: UIView? = view?.superview
            while let cur = v {
                cur.backgroundColor = .clear
                v = cur.superview
            }
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

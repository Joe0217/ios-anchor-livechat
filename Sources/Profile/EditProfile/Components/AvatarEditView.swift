import SwiftUI
import PhotosUI

/// 头像编辑组件（I-spec §2.6 / §6B.2 / §7.2）。
///
/// 审核态 UX 严格照 spec v2：**条件分支渲染**而非 PhotosPicker + overlay。
/// - 审核中：裸 `Button { toast() }` label 是头像图 + In Review overlay
/// - 非审核：`PhotosPicker` label 是头像图 + 底部小铅笔提示
///
/// 关键（对齐 rule swiftui-button-plain-hitarea.md）：Button 用 `.buttonStyle(.plain)`
/// + label 加 `.contentShape(Rectangle())` 确保头像圆形边界内完整可点。
///
/// **刻意偏离 H5**（2026-07-08 审查沉淀）：H5 profile/index.vue 头像审核中**仍允许** PhotosPicker
/// 重新上传（新图覆盖旧审核提交进入审核）。iOS 更保守：审核中禁止重传，仅 toast 提示等待。
/// 理由：避免用户"重复提交审核"导致后端排队多份审核请求 + iOS 审核态视觉更明确（覆盖徽章占中央）。
/// 若产品后续要求对齐 H5 允许重传，改法：把 `if isReviewing` 分支的 `Button { onReviewingTap }`
/// 改成 `PhotosPicker + .overlay(InReviewBadge)`，删掉 onReviewingTap 回调。
struct AvatarEditView: View {
    let avatarUrl: String
    /// 头像审核中（vaild=2）—— 编辑禁用 + 显示"In Review"徽章
    let isReviewing: Bool
    /// 头像被拒（vaild=3）—— 编辑允许（用户可换新的），但显示"Rejected"徽章告知
    /// 用户产品需求 2026-07-07：H5 index.vue:79-86 三态视觉，iOS 补齐 P1 gap
    let isRejected: Bool
    let onPick: (PhotosPickerItem) -> Void
    let onReviewingTap: () -> Void

    @State private var pickerItem: PhotosPickerItem?

    private let size: CGFloat = 80

    init(avatarUrl: String,
         isReviewing: Bool,
         isRejected: Bool = false,
         onPick: @escaping (PhotosPickerItem) -> Void,
         onReviewingTap: @escaping () -> Void) {
        self.avatarUrl = avatarUrl
        self.isReviewing = isReviewing
        self.isRejected = isRejected
        self.onPick = onPick
        self.onReviewingTap = onReviewingTap
    }

    var body: some View {
        Group {
            if isReviewing {
                // 审核中：Button 拦截点击 + toast + InReviewBadge 居中覆盖
                // 用户需求 2026-07-08 v2：徽章移到头像容器中间（不再挂头像下方）+ 文案变小
                Button(action: onReviewingTap) {
                    avatarContent
                        .overlay(
                            InReviewBadge(style: .overlay),
                            alignment: .center
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            } else {
                // 正常 / 被拒：均允许 PhotosPicker（拒绝态用户可换新的）
                // 拒绝态额外显示 Rejected 徽章告知用户
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    avatarContent
                        .overlay(
                            editBadge
                                .offset(x: 2, y: 2),
                            alignment: .bottomTrailing
                        )
                        .overlay(alignment: .bottom) {
                            if isRejected {
                                rejectedBadge.offset(y: 26)
                            }
                        }
                        .contentShape(Circle())
                }
                .onChange(of: pickerItem) { newItem in
                    if let newItem {
                        onPick(newItem)
                        pickerItem = nil
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Sub-views

    private var avatarContent: some View {
        AvatarView(url: URL(string: avatarUrl), size: size, kind: .anchor, persistent: true)
    }

    private var editBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Theme.Palette.brandOrange))
            .overlay(Circle().stroke(Theme.Palette.screenBackground, lineWidth: 2))
    }

    /// 被拒徽章（对齐 InReviewBadge overlay style 但用 xmark icon + Rejected 文案）
    private var rejectedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.profileMediaRejected)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }
}

#Preview {
    HStack(spacing: 40) {
        AvatarEditView(
            avatarUrl: "",
            isReviewing: false,
            onPick: { _ in },
            onReviewingTap: {}
        )
        AvatarEditView(
            avatarUrl: "",
            isReviewing: true,
            onPick: { _ in },
            onReviewingTap: {}
        )
    }
    .padding()
    .background(Theme.Palette.screenBackground)
}

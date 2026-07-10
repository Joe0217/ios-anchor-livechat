import SwiftUI

/// 举报用户 sheet（H-0 补齐，对齐 H5 `c-feedbackPopup.vue` type='userProfile' 分支）。
///
/// 交互（H5 line 137-175）：
/// - 底部半屏 popup（iOS 用 `.presentationDetents([.medium])`）
/// - 标题 "Report"
/// - 5 个原因单选（选中 pink 实心 / 未选空心圆圈）
/// - Description label + textarea（H5 `showDesciption=true` → 始终显示；非必填）
/// - 底部 Report 按钮（未选中原因前 disabled）
/// - 成功 → toast + 关闭
///
/// 使用：`.sheet(isPresented:)` 从 UserProfileView 菜单触发。
struct ReportUserSheet: View {

    /// 5 个原因（dictValue 是英文原文——H5 line 36-57 硬编码，非字典接口拉；提交时原样回传）
    enum Reason: String, Identifiable, CaseIterable {
        case incorrect  = "Incorrect information"
        case sexual     = "Sexual content"
        case harassment = "Harassment or repulsive Language"   // 注意 L 大写（H5 原文如此）
        case unreasonable = "Unreasonable demands"
        case other      = "Other"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .incorrect:    return L10n.reportReasonIncorrect
            case .sexual:       return L10n.reportReasonSexual
            case .harassment:   return L10n.reportReasonHarassment
            case .unreasonable: return L10n.reportReasonUnreasonable
            case .other:        return L10n.commonOther
            }
        }
    }

    let userId: String
    var service: ReportUserServiceProtocol = ReportUserService.shared
    /// 提交成功后触发（父页面据此关闭 sheet + 展示 toast）
    let onSubmitSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: Reason?
    @State private var descriptionText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorToast: String?

    /// H5 c-feedbackPopup:65 `maxlength="2000"`
    private let maxDescriptionLength = 2000

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()

            // 2026-07-10 通话内 sheet 高度受限（medium ~50% screen），reasonList + description
            // 可能超过 sheet 可视高 → ScrollView 包住中间可滚动区，title 顶固定 / submitButton 底固定。
            VStack(spacing: 0) {
                title
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        reasonList
                        descriptionSection
                    }
                }
                submitButton
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)

            toastOverlay
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Title

    private var title: some View {
        Text(L10n.reportTitle)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)
            .padding(.bottom, 18)
    }

    // MARK: - Reason list（H5 CThButton radio row）

    private var reasonList: some View {
        VStack(spacing: 0) {
            ForEach(Reason.allCases) { reason in
                reasonRow(reason)
            }
        }
    }

    private func reasonRow(_ reason: Reason) -> some View {
        Button {
            selectedReason = reason
        } label: {
            HStack(spacing: 12) {
                Text(reason.displayName)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: selectedReason == reason
                      ? "checkmark.circle.fill"
                      : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(selectedReason == reason
                                     ? Color(hex: 0xFF1AA7)
                                     : Color.white.opacity(0.5))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())   // 整行热区（对齐 rule swiftui-button-plain-hitarea）
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedReason == reason ? [.isSelected] : [])
    }

    // MARK: - Description（showDesciption=true 恒显）

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.reportDescriptionLabel)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.85))
                .padding(.top, 12)

            VStack(alignment: .trailing, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if descriptionText.isEmpty {
                        Text(L10n.reportDescriptionPlaceholder)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $descriptionText)
                        .frame(minHeight: 72)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .scrollContentBackground(.hidden)
                        .foregroundColor(.white)
                        .tint(Color(hex: 0xFF1AA7))
                        .onChange(of: descriptionText) { newValue in
                            if newValue.count > maxDescriptionLength {
                                descriptionText = String(newValue.prefix(maxDescriptionLength))
                            }
                        }
                }
                .background(
                    Color(hex: 0x0F0E0F).opacity(0.8),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                Text("\(descriptionText.count)/\(maxDescriptionLength)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Submit button

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack {
                Spacer()
                if isSubmitting {
                    ProgressView().tint(.white)
                } else {
                    Text(L10n.reportTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .background { submitButtonBackground }
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding(.top, 16)
    }

    private var canSubmit: Bool {
        selectedReason != nil && !isSubmitting
    }

    /// iOS 16 兼容：view-based `.background { shape.fill(...) }`（rule swiftui-background-in-shape-signature §正例 A）
    /// AnyShapeStyle 是 iOS 17+ API，工程 target 是 iOS 16，不用
    @ViewBuilder
    private var submitButtonBackground: some View {
        if canSubmit {
            Capsule().fill(
                LinearGradient(
                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
        } else {
            Capsule().fill(Color.gray.opacity(0.4))
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let msg = errorToast {
            VStack {
                Text(msg)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75), in: Capsule())
                Spacer()
            }
            .padding(.top, 40)
            .transition(.opacity)
            .task(id: msg) {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    errorToast = nil
                } catch { return }
            }
        }
    }

    // MARK: - Submit action

    @MainActor
    private func submit() async {
        guard let reason = selectedReason, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        let req = ReportUserRequest(
            suggestion: descriptionText,
            beBlockUid: userId,
            feedbackType: reason.rawValue
        )
        do {
            try await service.submit(req)
            onSubmitSuccess()   // 父页面收 toast + dismiss sheet
        } catch {
            errorToast = L10n.userProfileNetworkError
        }
    }
}

#if DEBUG
private final class PreviewReportService: ReportUserServiceProtocol {
    func submit(_ request: ReportUserRequest) async throws {}
}

#Preview("Report Sheet") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            ReportUserSheet(
                userId: "100001",
                service: PreviewReportService(),
                onSubmitSuccess: {}
            )
            .presentationDetents([.medium, .fraction(0.8)])
        }
        .preferredColorScheme(.dark)
}
#endif

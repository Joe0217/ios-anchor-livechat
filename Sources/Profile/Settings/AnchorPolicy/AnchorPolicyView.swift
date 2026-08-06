import SwiftUI

/// 107 Party-only 包的本地说明页。
///
/// 规范、用户协议和隐私政策不再加载失效的外部 H5；文案仅覆盖本包实际开放的 Party
/// 公屏、表情和免费互动能力，避免向审核人员或用户展示未开放功能。
struct AnchorPolicyView: View {
    var body: some View {
        NativeSettingsDocumentView(document: .anchorPolicy)
    }
}

struct UserAgreementView: View {
    var body: some View {
        NativeSettingsDocumentView(document: .userAgreement)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        NativeSettingsDocumentView(document: .privacyPolicy)
    }
}

private struct NativeSettingsDocumentView: View {
    let document: NativeSettingsDocument

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                documentHeader

                ForEach(document.sections) { section in
                    documentSection(section)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(Theme.Palette.profileBackground)
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: document.symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.Palette.blocklistName)
                .accessibilityHidden(true)

            Text(document.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)

            Text(document.introduction)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 28)
    }

    private func documentSection(_ section: NativeSettingsDocumentSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Text(section.body)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .padding(.bottom, 22)
        .overlay(alignment: .bottom) {
            Divider().overlay(Color.white.opacity(0.12))
        }
        .padding(.bottom, 22)
    }
}

private enum NativeSettingsDocument {
    case anchorPolicy
    case userAgreement
    case privacyPolicy

    var title: String {
        switch self {
        case .anchorPolicy: return L10n.settingsAnchorPolicy
        case .userAgreement: return L10n.settingsTermsOfService
        case .privacyPolicy: return L10n.settingsPrivacyPolicy
        }
    }

    var introduction: String {
        switch self {
        case .anchorPolicy: return L10n.settingsDocumentAnchorPolicyIntroduction
        case .userAgreement: return L10n.settingsDocumentAgreementIntroduction
        case .privacyPolicy: return L10n.settingsDocumentPrivacyIntroduction
        }
    }

    var symbolName: String {
        switch self {
        case .anchorPolicy: return "checkmark.shield"
        case .userAgreement: return "doc.text"
        case .privacyPolicy: return "hand.raised"
        }
    }

    var sections: [NativeSettingsDocumentSection] {
        switch self {
        case .anchorPolicy:
            return [
                .init(id: "respect", title: L10n.settingsDocumentAnchorPolicyRespectTitle, body: L10n.settingsDocumentAnchorPolicyRespectBody),
                .init(id: "content", title: L10n.settingsDocumentAnchorPolicyContentTitle, body: L10n.settingsDocumentAnchorPolicyContentBody),
                .init(id: "commercial", title: L10n.settingsDocumentAnchorPolicyCommercialTitle, body: L10n.settingsDocumentAnchorPolicyCommercialBody),
                .init(id: "safety", title: L10n.settingsDocumentAnchorPolicySafetyTitle, body: L10n.settingsDocumentAnchorPolicySafetyBody),
                .init(id: "moderation", title: L10n.settingsDocumentAnchorPolicyModerationTitle, body: L10n.settingsDocumentAnchorPolicyModerationBody)
            ]
        case .userAgreement:
            return [
                .init(id: "acceptance", title: L10n.settingsDocumentAgreementAcceptanceTitle, body: L10n.settingsDocumentAgreementAcceptanceBody),
                .init(id: "scope", title: L10n.settingsDocumentAgreementScopeTitle, body: L10n.settingsDocumentAgreementScopeBody),
                .init(id: "use", title: L10n.settingsDocumentAgreementUseTitle, body: L10n.settingsDocumentAgreementUseBody),
                .init(id: "content", title: L10n.settingsDocumentAgreementContentTitle, body: L10n.settingsDocumentAgreementContentBody),
                .init(id: "service", title: L10n.settingsDocumentAgreementServiceTitle, body: L10n.settingsDocumentAgreementServiceBody),
                .init(id: "account", title: L10n.settingsDocumentAgreementAccountTitle, body: L10n.settingsDocumentAgreementAccountBody),
                .init(id: "changes", title: L10n.settingsDocumentAgreementChangesTitle, body: L10n.settingsDocumentAgreementChangesBody)
            ]
        case .privacyPolicy:
            return [
                .init(id: "data", title: L10n.settingsDocumentPrivacyDataTitle, body: L10n.settingsDocumentPrivacyDataBody),
                .init(id: "use", title: L10n.settingsDocumentPrivacyUseTitle, body: L10n.settingsDocumentPrivacyUseBody),
                .init(id: "visibility", title: L10n.settingsDocumentPrivacyVisibilityTitle, body: L10n.settingsDocumentPrivacyVisibilityBody),
                .init(id: "sharing", title: L10n.settingsDocumentPrivacySharingTitle, body: L10n.settingsDocumentPrivacySharingBody),
                .init(id: "security", title: L10n.settingsDocumentPrivacySecurityTitle, body: L10n.settingsDocumentPrivacySecurityBody),
                .init(id: "choices", title: L10n.settingsDocumentPrivacyChoicesTitle, body: L10n.settingsDocumentPrivacyChoicesBody)
            ]
        }
    }
}

private struct NativeSettingsDocumentSection: Identifiable {
    let id: String
    let title: String
    let body: String
}

#if DEBUG
#Preview {
    NavigationStack { AnchorPolicyView() }
}
#endif

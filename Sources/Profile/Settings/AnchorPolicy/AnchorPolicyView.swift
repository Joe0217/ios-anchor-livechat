import SwiftUI

struct AnchorPolicyView: View {
    var body: some View {
        LegalDocumentView(fragment: "community-guidelines", title: L10n.settingsAnchorPolicy)
    }
}

struct UserAgreementView: View {
    var body: some View {
        LegalDocumentView(fragment: "terms", title: L10n.settingsTermsOfService)
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        LegalDocumentView(fragment: "privacy", title: L10n.settingsPrivacyPolicy)
    }
}

private struct LegalDocumentView: View {
    let fragment: String
    let title: String

    var body: some View {
        if let page = H5Page.legalDocument(fragment: fragment, title: title) {
            H5WebContainerView(page: page)
        } else {
            ZStack {
                Theme.Palette.profileBackground.ignoresSafeArea()
                Text(L10n.commonNoContent)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                AppLogger.net.error("[LegalDocument] HilyWebFeatureBaseURL missing or invalid")
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { AnchorPolicyView() }
}
#endif

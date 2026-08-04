import SwiftUI
import UIKit

/// 设置页：账号 / 通用 / 关于 / 退出登录。
///
/// **对齐 H5 蓝本**（`anchor-livechat-h5/src/views/settings/config.js`）9 项内容，保留 iOS 4 section 分组：
/// - Account: View Anchor Policy + Blocklist
/// - General: Language + Feedback（占位 toast）+ Clear Cache
/// - About: Version（rightText）+ Terms of Service + Privacy Policy（应用内安全 H5）
/// - Logout: Sign Out
///
/// **交互统一**：iOS 16 List 内 `NavigationLink(value:)` 与祖先 destination 交互失效，
/// 所有 push 均走 `path.append(ProfileRoute.xxx)` programmatic navigation（含 Blocklist）。
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var toastMessage: String?
    /// 子页路由 push 用（Blocklist / AnchorPolicy / Language）
    @Binding var path: NavigationPath

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            List {
                accountSection
                generalSection
                aboutSection
                #if DEBUG
                DebugPermissionSection()
                DebugCDNAssetUploadSection()
                #endif
                logoutSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.profileBackground)
        }
        .navigationTitle(L10n.settingsTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog(L10n.settingsLogoutConfirm,
                            isPresented: $showLogoutConfirm,
                            titleVisibility: .visible) {
            Button(L10n.settingsLogout, role: .destructive) {
                session.logout()
            }
            Button(L10n.settingsCancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.settingsClearCacheConfirm,
                            isPresented: $showClearCacheConfirm,
                            titleVisibility: .visible) {
            Button(L10n.settingsConfirm) {
                clearCache()
            }
            Button(L10n.settingsCancel, role: .cancel) {}
        }
        .overlay(alignment: .top) { toastOverlay }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section(L10n.settingsSectionAccount) {
            settingsRow(icon: "doc.text.magnifyingglass", title: L10n.settingsAnchorPolicy) {
                path.append(ProfileRoute.anchorPolicy)
            }
            settingsRow(icon: "person.text.rectangle", title: L10n.settingsBlocklist) {
                path.append(ProfileRoute.blocklist)
            }
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }

    private var generalSection: some View {
        Section(L10n.settingsSectionGeneral) {
            settingsRow(icon: "globe", title: L10n.settingsLanguage) {
                path.append(ProfileRoute.language)
            }
            settingsRow(icon: "envelope", title: L10n.settingsFeedback) {
                path.append(ProfileRoute.feedback)
            }
            settingsRow(icon: "trash", title: L10n.settingsClearCache) {
                showClearCacheConfirm = true
            }
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }

    private var aboutSection: some View {
        Section(L10n.settingsSectionAbout) {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22)
                Text(L10n.settingsVersion)
                    .foregroundColor(.white)
                Spacer()
                Text(Self.appVersion)
                    .foregroundColor(.white.opacity(0.5))
                    .font(.system(size: 13))
            }
            settingsRow(icon: "doc.text", title: L10n.settingsTermsOfService) {
                path.append(ProfileRoute.userAgreement)
            }
            settingsRow(icon: "lock.shield", title: L10n.settingsPrivacyPolicy) {
                path.append(ProfileRoute.privacyPolicy)
            }
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }

    private var logoutSection: some View {
        Section {
            Button {
                showLogoutConfirm = true
            } label: {
                HStack {
                    Spacer()
                    Text(L10n.settingsLogout)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.red.opacity(0.9))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }

    // MARK: - Row builder

    private func settingsRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsRowContent(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func settingsRowContent(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22)
            Text(title)
                .foregroundColor(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    /// 清缓存：账号图片缓存、URLCache 和公共礼物/运营资源文件缓存。
    private func clearCache() {
        ImageCache.shared.clear()
        ImageCache.shared.clearPublicAssets()
        showToast(L10n.settingsClearCacheDone)
    }

    // MARK: - Toast

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if toastMessage == msg { toastMessage = nil }
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let msg = toastMessage {
            Text(msg)
                .toastStyle()
                .transition(Toast.transition)
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

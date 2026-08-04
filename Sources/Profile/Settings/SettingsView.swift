import SwiftUI
import UIKit

/// 设置页：账号 / 通用 / 关于 / 删除账号 / 退出登录。
///
/// **对齐 H5 蓝本**（`anchor-livechat-h5/src/views/settings/config.js`）9 项内容，保留 iOS 4 section 分组：
/// - Account: View Anchor Policy + Blocklist
/// - General: Language + Feedback（占位 toast）+ Clear Cache
/// - About: Version（rightText）+ Terms of Service + Privacy Policy（应用内安全 H5）
/// - Account actions: Delete Account + Sign Out
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
                accountActionsSection
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

    private var accountActionsSection: some View {
        Section {
            Button {
                path.append(ProfileRoute.deleteAccount)
            } label: {
                centeredDestructiveLabel(L10n.settingsDeleteAccount)
            }
            .buttonStyle(.plain)

            Button {
                showLogoutConfirm = true
            } label: {
                centeredDestructiveLabel(L10n.settingsLogout)
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }

    private func centeredDestructiveLabel(_ title: String) -> some View {
        HStack {
            Spacer()
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.red.opacity(0.9))
            Spacer()
        }
        .contentShape(Rectangle())
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

// MARK: - Account deletion

/// 后端接口确认后只需替换生产实现；View/状态/会话清理不依赖具体 endpoint。
protocol AccountDeletionServiceProtocol {
    func deleteAccount() async throws
}

enum AccountDeletionError: Error {
    case notConfigured
}

final class AccountDeletionService: AccountDeletionServiceProtocol {
    static let shared = AccountDeletionService()

    private init() {}

    func deleteAccount() async throws {
        // 后端尚未提供 method/path/body。禁止把 logout 当删除成功，也禁止猜接口。
        throw AccountDeletionError.notConfigured
    }
}

@MainActor
final class AccountDeletionStore: ObservableObject {
    @Published private(set) var isDeleting = false
    @Published private(set) var errorMessage: String?

    private let service: AccountDeletionServiceProtocol

    init(service: AccountDeletionServiceProtocol = AccountDeletionService.shared) {
        self.service = service
    }

    func deleteAccount() async -> Bool {
        guard !isDeleting else { return false }
        isDeleting = true
        errorMessage = nil
        defer { isDeleting = false }

        do {
            try await service.deleteAccount()
            return true
        } catch AccountDeletionError.notConfigured {
            errorMessage = L10n.settingsDeleteAccountUnavailable
            return false
        } catch {
            errorMessage = L10n.settingsDeleteAccountFailed
            return false
        }
    }
}

/// 原生永久删除入口。服务端确认成功后才清本地会话；失败时保留登录态供用户重试。
struct AccountDeletionView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var store: AccountDeletionStore
    @State private var showConfirmation = false

    init(service: AccountDeletionServiceProtocol = AccountDeletionService.shared) {
        _store = StateObject(wrappedValue: AccountDeletionStore(service: service))
    }

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 58, weight: .regular))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text(L10n.settingsDeleteAccountTitle)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text(L10n.settingsDeleteAccountDescription)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        consequenceRow(L10n.settingsDeleteAccountConsequenceProfile)
                        consequenceRow(L10n.settingsDeleteAccountConsequenceContent)
                        consequenceRow(L10n.settingsDeleteAccountConsequenceRecovery)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.Palette.cardFill.opacity(0.6))
                    )

                    if let error = store.errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("accountDeletionError")
                    }

                    Button {
                        showConfirmation = true
                    } label: {
                        Group {
                            if store.isDeleting {
                                ProgressView().tint(.white)
                            } else {
                                Text(L10n.settingsDeleteAccountAction)
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(.white)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isDeleting)
                    .accessibilityIdentifier("deleteAccountButton")
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle(L10n.settingsDeleteAccount)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .confirmationDialog(
            L10n.settingsDeleteAccountConfirmTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.settingsDeleteAccountConfirmAction, role: .destructive) {
                Task {
                    if await store.deleteAccount() {
                        session.logout()
                    }
                }
            }
            Button(L10n.settingsCancel, role: .cancel) {}
        } message: {
            Text(L10n.settingsDeleteAccountConfirmMessage)
        }
    }

    private func consequenceRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red.opacity(0.9))
                .font(.system(size: 15))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

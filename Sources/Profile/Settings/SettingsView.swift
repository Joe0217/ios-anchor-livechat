import SwiftUI

/// 设置页：账号 / 通知 / 黑名单 / 语言 / 反馈 / 关于（版本号）/ 用户协议 / 隐私政策 / 退出登录。
///
/// L18 阶段实装：版本号显示 + 退出登录；其他条目仅作渲染占位（点击 no-op + 注释 TODO），
/// 后续里程碑（L19+）按需补完。蓝本 09 §86-98。
struct SettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirm = false

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            List {
                accountSection
                generalSection
                aboutSection
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
    }

    private var accountSection: some View {
        Section(L10n.settingsSectionAccount) {
            // I-1：黑名单列表。用 NavigationLink(value:) 沿 MainTabView 注册的
            // navigationDestination(for: ProfileRoute.self) 路由（spec §6.D）。
            NavigationLink(value: ProfileRoute.blocklist) {
                settingsRowContent(icon: "person.text.rectangle", title: L10n.settingsBlocklist)
            }
        }
        .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
    }

    private var generalSection: some View {
        Section(L10n.settingsSectionGeneral) {
            settingsRow(icon: "globe", title: L10n.settingsLanguage) { /* L20 */ }
            settingsRow(icon: "envelope", title: L10n.settingsFeedback) { /* L21 */ }
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
            settingsRow(icon: "doc.text", title: L10n.settingsTermsOfService) { /* TODO 外链 */ }
            settingsRow(icon: "lock.shield", title: L10n.settingsPrivacyPolicy) { /* TODO 外链 */ }
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

    private func settingsRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            settingsRowContent(icon: icon, title: title, showChevron: true)
        }
        .buttonStyle(.plain)
    }

    /// Row 内部视觉内容（图标 + 标题 + 可选 chevron）。
    /// NavigationLink(value:) 自带 disclosure chevron，调用 showChevron=false（默认）；
    /// Button 路径（旧入口）调用 showChevron=true 手动追加，保持视觉一致（review #19）。
    @ViewBuilder
    private func settingsRowContent(icon: String, title: String, showChevron: Bool = false) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22)
            Text(title)
                .foregroundColor(.white)
            Spacer()
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}

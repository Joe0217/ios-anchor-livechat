import Combine
import SwiftUI
import UIKit

/// 登录页（邮箱 + 密码，对应 H5 /views/login）+ A-2 注册流程分派入口
///
/// - A-2 spec §3.2 v3：顶层唯一 NavigationStack + 4 register view 分派；path 由 RegisterPathHolder.shared 持
/// - 2026-07-13：设计稿还原（登录页.png + 5 张切图），token 挂 Theme.Palette.auth* / Theme.Metric.auth*
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var pathHolder = RegisterPathHolder.shared
    @StateObject private var registerStore = RegisterStore.shared

    @State private var showEmailRegistration = false
    @State private var registrationReady = false
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordRevealed = false
    @State private var hasAcceptedLegalTerms = false
    @FocusState private var focusedField: LoginFocusField?

    var body: some View {
        NavigationStack(path: $pathHolder.path) {
            loginContent
                .onChange(of: session.pendingRegister) { pending in
                    if let p = pending {
                        email = p.email
                        showEmailRegistration = true
                        session.pendingRegister = nil     // 消费掉
                    }
                }
                // 2026-07-16：`needsResubmit` onChange 已删除。未审核账号登录后 RootView 分流到
                // RestrictedTabView,Resubmit 由 MineRestrictedView.handleResubmit 触发 hydrate + push。
                .navigationDestination(for: RegisterRoute.self) { route in
                    Group {
                        switch route {
                        case .basicInfo: RegisterBasicInfoView()
                        case .required: RegisterRequiredView()
                        case .videoRecord: RegisterVideoRecordView()
                        case .videoPreview: RegisterVideoPreviewView()
                        }
                    }
                    .environmentObject(registerStore)
                    .environmentObject(pathHolder)
                }
                .navigationDestination(for: LoginLegalRoute.self) { route in
                    switch route {
                    case .userAgreement: UserAgreementView()
                    case .privacyPolicy: PrivacyPolicyView()
                    }
                }
        }
        .sheet(isPresented: $showEmailRegistration, onDismiss: {
            if registrationReady {
                registrationReady = false
                pathHolder.path.append(RegisterRoute.basicInfo)
            }
        }) {
            EmailAccountView(mode: .registration, email: email, onRegistration: { address, secret, ticket, expiry in
                registerStore.beginVerified(email: address, password: secret, ticket: ticket, expiresAt: expiry)
                email = address
                registrationReady = true
            }, onLogin: { address in
                email = address
                session.errorMessage = L10n.Email.text("exists")
            })
        }
        .onChange(of: registerStore.returnToEmailLogin) { required in
            if required {
                email = registerStore.email
                pathHolder.reset()
                registerStore.reset()
                session.errorMessage = L10n.Email.text("exists")
            }
        }
        .onChange(of: registerStore.needsEmailVerification) { required in
            if required {
                email = registerStore.email
                pathHolder.reset()
                showEmailRegistration = true
            }
        }
    }

    private var loginContent: some View {
        ZStack {
            backgroundLayer
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer().frame(height: formTopSpacing)
                        titleImage
                        Spacer().frame(height: Theme.Metric.authTitleToEmailGap)
                        emailField
                        Spacer().frame(height: Theme.Metric.authInputGap)
                        passwordField
                        errorLine
                        legalConsent
                        Spacer().frame(height: 24)
                        loginButton
                            .id(LoginScrollTarget.loginButton)
                        registerButton
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, Theme.Metric.authScreenHPadding)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { field in
                    guard field != nil else { return }
                    scrollLoginButtonIntoView(proxy)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                    guard focusedField != nil else { return }
                    scrollLoginButtonIntoView(proxy)
                }
            }
        }
        .onChange(of: password) { value in
            if value.count > 20 { password = String(value.prefix(20)) }
        }
        .onChange(of: email) { value in
            let cleaned = String(EmailAccountRules.clean(value).prefix(100))
            if cleaned != value { email = cleaned }
        }
    }

    // MARK: - 组件

    private var backgroundLayer: some View {
        Theme.Gradients.partyRoomDefaultBackground
            .ignoresSafeArea()
    }

    /// 原标题位置 = 顶部间距 + logo 高度 + logo 到标题间距；去掉 logo 后仍按要求整体上移 100pt。
    private var formTopSpacing: CGFloat {
        max(
            24,
            Theme.Metric.authLogoTopGap
                + Theme.Metric.authLogoSize
                + Theme.Metric.authLogoToTitleGap
                - 100
        )
    }

    private var titleImage: some View {
        VStack(spacing: 8) {
            Text(L10n.Email.text("dailyTitle"))
                .font(.system(size: 32, weight: .heavy))
                .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.92, blue: 0.52), Color(red: 0.41, green: 0.82, blue: 1)], startPoint: .leading, endPoint: .trailing))
            Text(L10n.Email.text("wealthSubtitle")).foregroundStyle(.white.opacity(0.8))
        }.frame(maxWidth: .infinity)
    }

    private var emailField: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $email,
                prompt: Text(L10n.authEmail)
                    .foregroundColor(Theme.Palette.authInputPlaceholder)
                    .font(Theme.Typography.authInputPlaceh)
            )
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            .autocorrectionDisabled()
            .textContentType(.emailAddress)
            .foregroundColor(Theme.Palette.authInputText)
            .font(Theme.Typography.authInputText)
            .focused($focusedField, equals: .email)

            if !email.isEmpty {
                clearButton(text: $email, accessibilityLabel: L10n.authClearEmailA11y)
            }
        }
        .padding(.horizontal, Theme.Metric.authInputHPadding)
        .frame(height: Theme.Metric.authInputHeight)
        .background(
            Theme.Palette.authInputFill,
            in: RoundedRectangle(cornerRadius: Theme.Radius.authInput, style: .continuous)
        )
        .overlay(alignment: .top) {
            if focusedField == .email, email.isEmpty, !session.recentLoginAccounts.isEmpty {
                recentLoginAccounts
                    .padding(.top, Theme.Metric.authInputHeight + 8)
            }
        }
        .zIndex(focusedField == .email ? 1 : 0)
    }

    private var recentLoginAccounts: some View {
        VStack(spacing: 0) {
            ForEach(session.recentLoginAccounts, id: \.self) { account in
                HStack(spacing: 8) {
                    Button {
                        email = account
                        focusedField = .password
                    } label: {
                        Text(account)
                            .font(Theme.Typography.authInputText)
                            .foregroundStyle(Theme.Palette.authInputText)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(account)

                    Button(role: .destructive) {
                        session.removeRecentLoginAccount(account)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Palette.authInputIconTint)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.authRemoveRecentAccountA11y)
                }
                .padding(.leading, Theme.Metric.authInputHPadding)
                .padding(.trailing, 8)
                .frame(height: 48)

                if account != session.recentLoginAccounts.last {
                    Divider()
                        .overlay(Theme.Palette.authInputIconTint.opacity(0.3))
                        .padding(.leading, Theme.Metric.authInputHPadding)
                }
            }
        }
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: Theme.Radius.authInput, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.authInput, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 10, y: 5)
    }

    private var passwordField: some View {
        HStack(spacing: 12) {
            passwordInput
            if !password.isEmpty {
                clearButton(text: $password, accessibilityLabel: L10n.authClearPasswordA11y)
            }
            eyeToggleButton
        }
        .padding(.horizontal, Theme.Metric.authInputHPadding)
        .frame(height: Theme.Metric.authInputHeight)
        .background(
            Theme.Palette.authInputFill,
            in: RoundedRectangle(cornerRadius: Theme.Radius.authInput, style: .continuous)
        )
    }

    @ViewBuilder
    private var passwordInput: some View {
        // TextField / SecureField 分支切换会 dismantle → 通过 @FocusState 恢复焦点
        // TextField 明文分支不加 textContentType(.password),避免 iOS Password Autofill
        // 弹条误往可见字段写入
        if isPasswordRevealed {
            TextField(
                "",
                text: $password,
                prompt: Text(L10n.authPassword)
                    .foregroundColor(Theme.Palette.authInputPlaceholder)
                    .font(Theme.Typography.authInputPlaceh)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundColor(Theme.Palette.authInputText)
            .font(Theme.Typography.authInputText)
            .focused($focusedField, equals: .password)
        } else {
            SecureField(
                "",
                text: $password,
                prompt: Text(L10n.authPassword)
                    .foregroundColor(Theme.Palette.authInputPlaceholder)
                    .font(Theme.Typography.authInputPlaceh)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .foregroundColor(Theme.Palette.authInputText)
            .font(Theme.Typography.authInputText)
            .focused($focusedField, equals: .password)
        }
    }

    private func clearButton(text: Binding<String>, accessibilityLabel: String) -> some View {
        Button {
            text.wrappedValue = ""
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.Palette.authInputIconTint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var eyeToggleButton: some View {
        Button(action: togglePasswordVisibility) {
            // 不用 .renderingMode(.template) —— 切图设计为白色 glyph,
            // 保留原色可避免 template 模式对多色 icon 的意外抹平（reviewer F-1）
            CDNAssetImage(isPasswordRevealed ? "authEyeOpen" : "authEyeClosed")
                .resizable()
                .scaledToFit()
                .frame(
                    width: Theme.Metric.authEyeIconSize,
                    height: Theme.Metric.authEyeIconSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.authTogglePasswordA11y)
    }

    @ViewBuilder
    private var errorLine: some View {
        if !session.errorMessage.isEmpty {
            Text(session.errorMessage)
                .font(Theme.Typography.authError)
                .foregroundColor(Theme.Palette.authErrorText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Metric.authErrorVPadding)
                .padding(.horizontal, Theme.Metric.authErrorHPadding)
        }
    }

    private var loginButton: some View {
        Button(action: handleLogin) {
            HStack(spacing: 8) {
                if session.isLoading {
                    ProgressView().tint(Theme.Palette.authLoginButtonText)
                }
                Text(session.isLoading ? L10n.authLoggingIn : L10n.authLogin)
                    .font(Theme.Typography.authLoginButton)
                    .foregroundColor(Theme.Palette.authLoginButtonText)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.Metric.authLoginBtnHeight)
            .background(
                Theme.Palette.authLoginButton,
                in: RoundedRectangle(cornerRadius: Theme.Radius.authLoginBtn, style: .continuous)
            )
            .opacity(loginButtonEnabled ? 1.0 : 0.6)
        }
        .disabled(!loginButtonEnabled)
    }

    private var registerButton: some View {
        Button {
            guard hasAcceptedLegalTerms else { return }
            showEmailRegistration = true
            RegisterAnalytics.report(.signUp)
        } label: {
            Text(L10n.Email.text("signUp"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.authLoginButton)
                .frame(maxWidth: .infinity).frame(height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!hasAcceptedLegalTerms || session.isLoading)
        .opacity(hasAcceptedLegalTerms ? 1 : 0.5)
    }

    private var legalConsent: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                hasAcceptedLegalTerms.toggle()
            } label: {
                Image(systemName: hasAcceptedLegalTerms ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(hasAcceptedLegalTerms ? Theme.Palette.authLoginButton : .white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.authConsentToggleA11y)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.authConsentPrefix)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        legalLink(L10n.settingsTermsOfService, route: .userAgreement)
                        Text(L10n.authConsentAnd)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                        legalLink(L10n.settingsPrivacyPolicy, route: .privacyPolicy)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        legalLink(L10n.settingsTermsOfService, route: .userAgreement)
                        legalLink(L10n.settingsPrivacyPolicy, route: .privacyPolicy)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private func legalLink(_ title: String, route: LoginLegalRoute) -> some View {
        Button {
            pathHolder.path.append(route)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.authLoginButton)
                .underline()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func handleLogin() {
        email = EmailAccountRules.clean(email)
        Task { await session.login(email: email, password: password) }
    }

    private func togglePasswordVisibility() {
        // 记录切换前的 focus 状态；若正在编辑,切换后异步恢复,避免键盘收起
        let wasFocused = focusedField == .password
        isPasswordRevealed.toggle()
        if wasFocused {
            DispatchQueue.main.async {
                focusedField = .password
            }
        }
    }

    private func scrollLoginButtonIntoView(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(LoginScrollTarget.loginButton, anchor: .bottom)
            }
        }
    }

    // MARK: - 派生

    private var loginButtonEnabled: Bool {
        !session.isLoading && !email.isEmpty && !password.isEmpty && hasAcceptedLegalTerms
    }
}

private enum LoginLegalRoute: Hashable {
    case userAgreement
    case privacyPolicy
}

private enum LoginFocusField: Hashable {
    case email
    case password
}

private enum LoginScrollTarget: Hashable {
    case loginButton
}

#if DEBUG
#Preview("Login") {
    LoginView()
        .environmentObject(SessionStore.shared)
}
#endif

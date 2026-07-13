import SwiftUI

/// 登录页（邮箱 + 密码，对应 H5 /views/login）+ A-2 注册流程分派入口
///
/// - A-2 spec §3.2 v3：顶层唯一 NavigationStack + 4 register view 分派；path 由 RegisterPathHolder.shared 持
/// - 2026-07-13：设计稿还原（登录页.png + 5 张切图），token 挂 Theme.Palette.auth* / Theme.Metric.auth*
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var pathHolder = RegisterPathHolder.shared
    @StateObject private var registerStore = RegisterStore.shared

    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordRevealed = false
    // 眼睛切换后恢复密码框焦点，避免 TextField ↔ SecureField dismantle 导致的键盘收起
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack(path: $pathHolder.path) {
            loginContent
                .onChange(of: session.pendingRegister) { pending in
                    if let p = pending {
                        registerStore.begin(email: p.email, password: p.password)
                        pathHolder.path.append(RegisterRoute.basicInfo)
                        session.pendingRegister = nil     // 消费掉
                    }
                }
                .onChange(of: session.needsResubmit) { rs in
                    if let rs {
                        let cachedPwd = KeychainStore.getString(for: KeychainKey.pendingRegisterPassword)
                        registerStore.hydrate(from: rs.mineInfo, cachedPassword: cachedPwd)
                        pathHolder.path.append(RegisterRoute.basicInfo)
                        session.needsResubmit = nil
                    }
                }
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
        }
    }

    private var loginContent: some View {
        ZStack {
            backgroundLayer
            VStack(spacing: 0) {
                Spacer().frame(height: Theme.Metric.authLogoTopGap)
                logo
                Spacer().frame(height: Theme.Metric.authLogoToTitleGap)
                titleImage
                Spacer().frame(height: Theme.Metric.authTitleToEmailGap)
                emailField
                Spacer().frame(height: Theme.Metric.authInputGap)
                passwordField
                errorLine
                Spacer().frame(height: Theme.Metric.authPasswordToLoginGap)
                loginButton
                Spacer().frame(height: Theme.Metric.authLoginToForgetGap)
                forgetButton
                Spacer()
            }
            .padding(.horizontal, Theme.Metric.authScreenHPadding)
        }
    }

    // MARK: - 组件

    private var backgroundLayer: some View {
        Theme.Palette.authBackgroundFallback
            .overlay {
                Image("authLoginBackground")
                    .resizable()
                    .scaledToFill()
            }
            .ignoresSafeArea()
    }

    private var logo: some View {
        Image("authLogoHily")
            .resizable()
            .scaledToFit()
            .frame(width: Theme.Metric.authLogoSize, height: Theme.Metric.authLogoSize)
            .accessibilityHidden(true)
    }

    private var titleImage: some View {
        Image("authLoginTitle")
            .resizable()
            .scaledToFit()
            .frame(height: Theme.Metric.authTitleHeight)
            .accessibilityLabel(L10n.authTitle)
    }

    private var emailField: some View {
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
        .padding(.horizontal, Theme.Metric.authInputHPadding)
        .frame(height: Theme.Metric.authInputHeight)
        .background(
            Theme.Palette.authInputFill,
            in: RoundedRectangle(cornerRadius: Theme.Radius.authInput, style: .continuous)
        )
    }

    private var passwordField: some View {
        HStack(spacing: 12) {
            passwordInput
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
            .focused($passwordFocused)
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
            .focused($passwordFocused)
        }
    }

    private var eyeToggleButton: some View {
        Button(action: togglePasswordVisibility) {
            // 不用 .renderingMode(.template) —— 切图设计为白色 glyph,
            // 保留原色可避免 template 模式对多色 icon 的意外抹平（reviewer F-1）
            Image(isPasswordRevealed ? "authEyeOpen" : "authEyeClosed")
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

    private var forgetButton: some View {
        Button(action: handleForget) {
            Text(L10n.authForgetPassword)
                .font(Theme.Typography.authForget)
                .foregroundColor(Theme.Palette.authForgetText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func handleLogin() {
        Task { await session.login(email: email, password: password) }
    }

    private func handleForget() {
        // TODO: 忘记密码路由(未来对齐 H5 /views/forgetPwd)
    }

    private func togglePasswordVisibility() {
        // 记录切换前的 focus 状态；若正在编辑,切换后异步恢复,避免键盘收起
        let wasFocused = passwordFocused
        isPasswordRevealed.toggle()
        if wasFocused {
            DispatchQueue.main.async {
                passwordFocused = true
            }
        }
    }

    // MARK: - 派生

    private var loginButtonEnabled: Bool {
        !session.isLoading && !email.isEmpty && !password.isEmpty
    }
}

#if DEBUG
#Preview("Login") {
    LoginView()
        .environmentObject(SessionStore.shared)
}
#endif

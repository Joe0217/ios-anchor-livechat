import SwiftUI

/// 登录页（邮箱 + 密码，对应 H5 /views/login）。
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Text(L10n.authTitle).font(.largeTitle).bold().foregroundStyle(.white)
                Text(L10n.authEnvHint).font(.caption).foregroundStyle(.secondary)

                VStack(spacing: 14) {
                    TextField("", text: $email,
                              prompt: Text(L10n.authEmail).foregroundColor(.white.opacity(0.5)))
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                    SecureField("", text: $password,
                                prompt: Text(L10n.authPassword).foregroundColor(.white.opacity(0.5)))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                    if !session.errorMessage.isEmpty {
                        Text(session.errorMessage)
                            .font(.footnote).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await session.login(email: email, password: password) }
                    } label: {
                        HStack(spacing: 8) {
                            if session.isLoading { ProgressView().tint(.white) }
                            Text(session.isLoading ? L10n.authLoggingIn : L10n.authLogin)
                                .font(.headline).foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.pink, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(session.isLoading || email.isEmpty || password.isEmpty)
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))

                Spacer()
                Spacer()
            }
            .padding(24)
        }
    }
}

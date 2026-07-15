import SwiftUI

/// Page 1 基本信息（对齐 `注册1.png` / `注册-填写好状态.png`）
///
/// 字段：头像 / 昵称 / 生日+国家(并排) / Required fields row / 邀请码；底部 Sign Up → append(.required)
struct RegisterBasicInfoView: View {
    @EnvironmentObject var store: RegisterStore
    @EnvironmentObject var pathHolder: RegisterPathHolder

    @State private var showBirthdayPicker = false
    @State private var showCountryPicker = false
    @State private var toastMsg: String? = nil

    private let validator = RegisterFormValidator()

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    RegisterAvatarPickerView(store: store)
                        .padding(.top, 40)

                    fieldGroup

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
            }

            VStack {
                Spacer()
                signUpButton
                    .padding(.horizontal, 30)
                    .padding(.bottom, 20)
            }

            if let msg = toastMsg {
                VStack {
                    Text(msg).toastStyle()
                    Spacer()
                }
            }
        }
        .onChange(of: store.avatarUploadError) { err in
            if let err { showToast(err) }
        }
        .navigationBarBackButtonHidden(true)   // 副作用禁左滑关闭，业务态防误退（2026-07-11 用户明示注册所有页禁左滑）
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    pathHolder.reset()   // 回退登录页时清 path
                } label: {
                    Image(systemName: "chevron.left").foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $showBirthdayPicker) {
            BirthdayPickerSheet(isPresented: $showBirthdayPicker, birthday: $store.birthday)
                .giftPanelSheetBackground()
        }
        .sheet(isPresented: $showCountryPicker) {
            CountryPickerSheet(isPresented: $showCountryPicker) { country in
                store.countryCode = country.locale
                store.countryName = country.en
            }
            .giftPanelSheetBackground()
        }
    }

    private var fieldGroup: some View {
        VStack(spacing: 12) {
            // Nickname (with 0/15 counter)
            HStack {
                TextField(
                    "",
                    text: $store.nickname,
                    prompt: Text(L10n.Register.fieldNickname).foregroundColor(.white.opacity(0.5))
                )
                .foregroundStyle(.white)
                .onChange(of: store.nickname) { newVal in
                    if newVal.count > 15 { store.nickname = String(newVal.prefix(15)) }
                }
                Text("\(store.nickname.count)/15")
                    .font(.caption)
                    .foregroundStyle(Color(red: 0.62, green: 0.49, blue: 0.86))
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color(red: 0.17, green: 0.13, blue: 0.24), in: RoundedRectangle(cornerRadius: 22))

            // Birthday + Country 并排
            HStack(spacing: 10) {
                fieldRow(text: store.birthday.isEmpty ? L10n.Register.fieldBirthday : store.birthday,
                         placeholder: store.birthday.isEmpty)
                    .onTapGesture { showBirthdayPicker = true }
                fieldRow(text: store.countryName ?? (store.countryCode ?? L10n.Register.fieldCountry),
                         placeholder: store.countryName == nil && store.countryCode == nil)
                    .onTapGesture { showCountryPicker = true }
            }

            // Required fields row
            HStack {
                Text(L10n.Register.fieldRequiredFields).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color(red: 0.17, green: 0.13, blue: 0.24), in: RoundedRectangle(cornerRadius: 22))
            .contentShape(Rectangle())
            .onTapGesture {
                pathHolder.path.append(RegisterRoute.required)
            }

            // Invite code (optional)
            Text(L10n.Register.fieldInviteCode)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            TextField(
                "",
                text: $store.inviteCode,
                prompt: Text(L10n.Register.fieldInviteCodeOptional).foregroundColor(.white.opacity(0.5))
            )
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color(red: 0.17, green: 0.13, blue: 0.24), in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func fieldRow(text: String, placeholder: Bool) -> some View {
        HStack {
            Text(text).foregroundStyle(placeholder ? .white.opacity(0.5) : .white).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(Color(red: 0.17, green: 0.13, blue: 0.24), in: RoundedRectangle(cornerRadius: 22))
        .contentShape(Rectangle())
    }

    private var signUpButton: some View {
        Button {
            let result = validator.validatePage1(
                iconUrl: store.iconUrl,
                nickname: store.nickname,
                birthday: store.birthday,
                countryCode: store.countryCode
            )
            switch result {
            case .ok:
                pathHolder.path.append(RegisterRoute.required)
            case .missingAvatar: showToast(L10n.Register.errorAvatarRequired)
            case .missingNickname: showToast(L10n.Register.errorNicknameRequired)
            case .missingBirthday: showToast(L10n.Register.errorBirthdayRequired)
            case .missingCountry: showToast(L10n.Register.errorCountryRequired)
            default: break
            }
        } label: {
            Text(L10n.Register.actionSignUp)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
        }
    }

    private func showToast(_ msg: String) {
        toastMsg = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
            toastMsg = nil
        }
    }
}

import SwiftUI

/// Page 2 必填资料（对齐 `必填资料-未填时.png` / `必填资料-填写完整时.png` / `必填资料-已上传.png`）
struct RegisterRequiredView: View {
    @EnvironmentObject var store: RegisterStore
    @EnvironmentObject var pathHolder: RegisterPathHolder

    @State private var showLanguagePicker = false
    @State private var showVideoGuide = false
    @State private var toastMsg: String? = nil

    private let validator = RegisterFormValidator()

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Language
                    section(title: L10n.Register.fieldYourLanguage) {
                        HStack {
                            Text(store.languages.isEmpty
                                 ? L10n.Register.fieldSelectLanguage
                                 : store.languages.joined(separator: ", "))
                                .foregroundStyle(store.languages.isEmpty ? .white.opacity(0.5) : .white)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 14).frame(height: 44)
                        .background(Color(red: 0.17, green: 0.13, blue: 0.24), in: RoundedRectangle(cornerRadius: 22))
                        .onTapGesture { showLanguagePicker = true }
                    }

                    // Photos
                    section(title: L10n.Register.fieldYourPhotos(6)) {
                        RegisterPhotosGrid(store: store)
                    }

                    // Video
                    section(title: L10n.Register.fieldTakeVideo) {
                        VideoSlotView(store: store) { showVideoGuide = true }
                    }

                    Spacer(minLength: 80)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }

            VStack {
                Spacer()
                submitButton
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
        .onChange(of: store.submitError) { err in
            // 2026-07-12 同步 H5：原红色 banner 常驻 → 改 toast 2s 自动消失（对齐 H5 showNotify 交互 duration 1500ms）
            // 内容保持后端 message 原文（H5 拦截器 line 124-130 也是直显后端 message 字面，如 1076 → "invite.code.not.exist"）
            if let err {
                showToast(err)
                store.submitError = nil   // 立即清掉，避免下一次 onChange 或 view rebuild 重复
            }
        }
        .navigationTitle(L10n.Register.titleRequired)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)   // Bug fix 2026-07-08：隐藏系统 back，用自定义 chevron.left 单一 back；副作用禁左滑（2026-07-11 业务态防误退）
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Finding #6 修：guard path 非空
                    guard !pathHolder.path.isEmpty else { return }
                    pathHolder.path.removeLast()
                } label: {
                    Image(systemName: "chevron.left").foregroundStyle(.white)
                }
            }
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerSheet(isPresented: $showLanguagePicker, selected: $store.languages)
        }
        .sheet(isPresented: $showVideoGuide) {
            VideoGuideSheet(isPresented: $showVideoGuide) {
                pathHolder.path.append(RegisterRoute.videoRecord)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.purple)
                    .font(.caption)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            content()
        }
    }

    private var submitButton: some View {
        Button {
            let result = validator.validatePage2(languages: store.languages, picUrls: store.picUrls, videoUrl: store.videoUrl)
            switch result {
            case .ok:
                Task {
                    RegisterAnalytics.report(.reviewInf)
                    await store.submit()
                }
            case .missingLanguage: showToast(L10n.Register.errorLanguageRequired)
            case .missingPhotos: showToast(L10n.Register.errorPhotosMin(6))
            case .missingVideo: showToast(L10n.Register.errorVideoRequired)
            default: break
            }
        } label: {
            HStack(spacing: 8) {
                if store.isSubmitting { ProgressView().tint(.white) }
                Text(store.isResubmit
                     ? L10n.Register.actionEdit
                     : L10n.Register.actionUpload)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                in: Capsule()
            )
        }
        .disabled(store.isSubmitting)
    }

    private func showToast(_ msg: String) {
        toastMsg = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
            toastMsg = nil
        }
    }
}

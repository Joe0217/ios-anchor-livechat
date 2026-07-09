import Foundation
import SwiftUI
import os

/// 注册流程表单/进度/生命周期收敛点（对齐 spec §3.1 v3）
///
/// 单例模式（对齐 SessionStore / AnchorInfoStore 现有惯例），
/// logout hook 清 store（session-scoped rule 应用；本 store 不属账号级快照 store，不挂 login refresh）
@MainActor
final class RegisterStore: ObservableObject {
    static let shared = RegisterStore()
    private init() {}

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "RegisterStore")

    // MARK: - 表单持久字段（对齐 H5 register.js formData）

    @Published var email: String = ""           // login catch 1005 时携入
    @Published var password: String = ""        // 明文；submit 时走 CryptoUtil.loginPassword 转两次 MD5 upper
    @Published var iconUrl: String? = nil
    @Published var nickname: String = ""
    @Published var birthday: String = ""        // "yyyy-MM-dd"
    @Published var countryCode: String? = nil   // ISO locale (对齐 H5 formData.countryId 语义)
    @Published var countryName: String? = nil   // en 显示
    @Published var inviteCode: String = ""
    @Published var languages: [String] = []     // 1-4 selected
    @Published var picUrls: [String] = []       // 6 OSS URLs
    @Published var videoUrl: String? = nil      // OSS URL
    @Published var gender: Int = 2              // 主播端默认女
    @Published var deviceId: String = ""        // 由 SessionStore.applyLogin 时更新 or DeviceInfo.deviceId 直读
    @Published var phone: String = ""           // H5 form 无 phone input，但 hydrate 时应从 mineInfo 回填避免 resubmit 覆盖后端记录

    // MARK: - 进行态

    @Published var isAvatarUploading: Bool = false
    /// Avatar 上传失败错误（与 submitError 分离，避免 Page 1 错误穿到 Page 2 banner）
    @Published var avatarUploadError: String? = nil
    @Published var picUploadTasks: [PhotoUploadTask] = []
    @Published var localVideoOriginalUrl: URL? = nil
    @Published var localVideoCompressedUrl: URL? = nil
    @Published var videoCompressProgress: Double? = nil     // nil 未开始 / 0..1 / 1.0 完成
    @Published var isVideoUploading: Bool = false
    @Published var isSubmitting: Bool = false
    @Published var submitError: String? = nil

    // MARK: - 场景标记

    /// 被拒重录场景：session.needsResubmit trigger → hydrate 后置 true → Submit 走 A3 hostReSubmitView
    @Published var isResubmit: Bool = false

    // MARK: - 生命周期

    /// 首次注册进入前：LoginView 监听 session.pendingRegister → 携 email/password
    func begin(email: String, password: String) {
        self.email = email
        self.password = password
        self.isResubmit = false
        logger.info("[RegisterStore] begin firstTime email=\(email, privacy: .private)")
    }

    /// 被拒重录进入前：LoginView 监听 session.needsResubmit → 携 mineInfo + Keychain cached password
    ///
    /// v3 NEW-5：cachedPassword nil 时从 Keychain 兜底读（KeychainKey.pendingRegisterPassword）
    func hydrate(from mineInfo: AnchorInfo, cachedPassword: String? = nil) {
        self.email = mineInfo.email ?? ""
        self.password = cachedPassword
            ?? KeychainStore.getString(for: KeychainKey.pendingRegisterPassword)
            ?? ""
        self.iconUrl = mineInfo.icon
        self.nickname = mineInfo.nickname ?? ""
        self.birthday = mineInfo.birthday ?? ""
        self.countryCode = mineInfo.countryCode      // ISO 两字母（供国旗显示）
        self.countryName = mineInfo.countryId        // Bug fix 2026-07-08：H5 formData.countryId 存 en 名（"Spain"），不是 locale；hydrate 从 T0.2 扩的 countryId 字段读取
        self.inviteCode = mineInfo.inviteCode ?? ""
        self.languages = (mineInfo.language ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 注意：picList / videos **不** hydrate 到本 store（spec §0.14 一期简化——iOS 视频独立字段，picList 尾部作视频的 hack 不移植；用户重录时重新上传）
        self.picUrls = []
        self.videoUrl = nil
        self.gender = mineInfo.sex ?? 2
        self.deviceId = DeviceInfo.deviceId
        self.phone = mineInfo.phone ?? ""
        self.isResubmit = true
        logger.info("[RegisterStore] hydrated resubmit userId=\(mineInfo.userId ?? -1, privacy: .private) email=\(mineInfo.email ?? "", privacy: .private)")
    }

    /// 冷启动清 / logout 清 / 注册成功清
    func reset() {
        email = ""
        password = ""
        iconUrl = nil
        nickname = ""
        birthday = ""
        countryCode = nil
        countryName = nil
        inviteCode = ""
        languages = []
        picUrls = []
        videoUrl = nil
        gender = 2
        deviceId = ""
        phone = ""

        isAvatarUploading = false
        avatarUploadError = nil
        picUploadTasks = []
        localVideoOriginalUrl = nil
        localVideoCompressedUrl = nil
        videoCompressProgress = nil
        isVideoUploading = false
        isSubmitting = false
        submitError = nil

        isResubmit = false
        logger.info("[RegisterStore] reset")
    }

    // MARK: - Submit（Page 2 底部 Upload 按钮触发）

    /// 提交注册（首次走 A2 registerV2 / 重录走 A3 reSubmitView）→ SessionStore.applyLogin → 主页
    ///
    /// spec §3.3 v3 完整流：build body → API 调用 → applyLogin bool 守卫 → 清 Keychain → reset → 依 isLoggedIn 走 RootView 分流
    func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        let body = RegisterSubmitBody(
            email: email,
            password: CryptoUtil.loginPassword(password),
            iconUrl: iconUrl ?? "",
            nickname: nickname,
            birthday: birthday,
            countryId: countryName ?? (countryCode ?? ""),   // Bug fix 2026-07-08：优先用 countryName (en 名 "Spain")，对齐 H5 registerForm.vue:110 `formData.countryId = item.text`（en 名）；locale fallback 兜底
            inviteCode: inviteCode,
            language: languages.joined(separator: ","),
            picList: picUrls,
            videos: [videoUrl].compactMap { $0 },
            gender: gender,
            deviceId: DeviceInfo.deviceId,
            phone: phone
        )

        do {
            let result = try await (isResubmit
                ? RegisterService.reSubmitView(body: body)
                : RegisterService.registerV2(body: body))

            // v3 NEW-6: applyLogin 返 Bool；false 表示 token 缺失
            guard await SessionStore.shared.applyLogin(result) else {
                submitError = L10n.authErrorNoToken
                return
            }
            // resubmit 场景清短期 Keychain 密码
            _ = KeychainStore.remove(for: KeychainKey.pendingRegisterPassword)
            RegisterAnalytics.report(.appSign)
            logger.info("[RegisterStore] submit success userId=\(result.userId ?? -1, privacy: .private) isResubmit=\(self.isResubmit, privacy: .public)")
            reset()
        } catch let e as APIError {
            submitError = e.message
            logger.error("[RegisterStore] submit APIError code=\(e.code, privacy: .public) msg=\(e.message, privacy: .public)")
        } catch {
            submitError = String(format: L10n.authErrorNetworkFormat, error.localizedDescription)
            logger.error("[RegisterStore] submit network error \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 照片上传进度辅助（RegisterPhotosGrid 消费）

    func setPicSucceeded(id: UUID, url: String) {
        if let idx = picUploadTasks.firstIndex(where: { $0.id == id }) {
            picUploadTasks[idx].state = .succeeded(url: url)
        }
        picUrls = picUploadTasks.compactMap { $0.succeededUrl }
    }

    func setPicFailed(id: UUID, error: String) {
        if let idx = picUploadTasks.firstIndex(where: { $0.id == id }) {
            picUploadTasks[idx].state = .failed(error: error)
        }
    }

    func removePicTask(id: UUID) {
        picUploadTasks.removeAll { $0.id == id }
        picUrls = picUploadTasks.compactMap { $0.succeededUrl }
    }
}

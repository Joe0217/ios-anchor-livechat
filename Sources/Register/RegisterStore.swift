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
    /// P1-2 修 2026-07-12：快速切换头像 A→B 若 B 先完成 A 后到 → iconUrl 被 A 覆盖 race。
    /// upload Task 完成时判 epoch 不一致 → 丢弃结果（对齐 videoCompressEpoch 模式）
    @Published var avatarUploadEpoch: Int = 0
    @Published var picUploadTasks: [PhotoUploadTask] = []
    @Published var localVideoOriginalUrl: URL? = nil
    @Published var localVideoCompressedUrl: URL? = nil
    @Published var videoCompressProgress: Double? = nil     // nil 未开始 / 0..1 / 1.0 完成
    /// Finding #2 修 2026-07-10：Re-record 时递增，让在飞的旧压缩 Task 完成时判 epoch 不一致 → 丢弃结果不覆盖 store
    @Published var videoCompressEpoch: Int = 0
    @Published var isVideoUploading: Bool = false
    @Published var isSubmitting: Bool = false
    @Published var submitError: String? = nil

    // MARK: - 场景标记

    /// 被拒重录场景：MineRestrictedView.handleResubmit trigger → hydrate 后置 true → Submit 走 A3 hostReSubmitView
    /// (2026-07-16 前是 LoginView session.needsResubmit onChange 触发,重构后迁到受限首屏的 Resubmit 按钮)
    @Published var isResubmit: Bool = false

    /// Finding #12 修 2026-07-10：VideoSlotView 判"是否已录"派生态；
    /// 原 view 层同 view 内 2 处判定条件不一致（× 按钮 vs 缩略图），此处统一"有任何视频状态"即视为已录
    var hasVideo: Bool {
        videoUrl != nil || localVideoOriginalUrl != nil || localVideoCompressedUrl != nil
    }

    // MARK: - 生命周期

    /// 首次注册进入前：LoginView 监听 session.pendingRegister → 携 email/password
    ///
    /// Finding #3 修 2026-07-10：先 reset() 再赋 email/password，避免 A 用户半途放弃后 B 用户进注册看到 A 的 stale 头像/昵称/生日
    /// （原实现只覆盖 email/password/isResubmit 3 字段，其它保留跨账号）
    func begin(email: String, password: String) {
        reset()
        self.email = email
        self.password = password
        self.isResubmit = false
        logger.info("[RegisterStore] begin firstTime email=\(email, privacy: .private)")
    }

    /// 被拒重录进入前：MineRestrictedView 直接携当前已加载的 mineInfo + Keychain cached password。
    /// (2026-07-16 前挂 LoginView 监听 session.needsResubmit,重构后迁到受限首屏 Resubmit 按钮)
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
        // 与 H5 userStore.setMinePicList 同样按 mediaType 分流。picList 是当前接口的
        // 权威媒体字段；pictures/videos 仅为旧响应的兼容回退。
        let typedPhotos = (mineInfo.picList ?? []).compactMap { item -> String? in
            guard item.mediaType == 1,
                  let url = item.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { return nil }
            return url
        }
        let typedVideos = (mineInfo.picList ?? []).compactMap { item -> String? in
            guard item.mediaType == 2,
                  let url = item.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty else { return nil }
            return url
        }
        let legacyPhotos = (mineInfo.pictures ?? []).compactMap { asset -> String? in
            guard let url = asset.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }
            return url
        }
        let legacyVideos = (mineInfo.videos ?? []).compactMap { asset -> String? in
            guard let url = asset.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }
            return url
        }
        let photoURLs = Array((typedPhotos.isEmpty ? legacyPhotos : typedPhotos).prefix(6))
        self.picUrls = photoURLs
        self.videoUrl = (typedVideos.isEmpty ? legacyVideos : typedVideos).first

        // 照片网格以上传任务为渲染数据源。把服务端 URL 还原为成功态任务，后续删除、
        // 新增和提交都会同步更新 picUrls，不会在重提时遗漏原有图片。
        self.picUploadTasks = photoURLs.map {
            PhotoUploadTask(id: UUID(), localData: Data(), state: .succeeded(url: $0))
        }
        self.localVideoOriginalUrl = nil
        self.localVideoCompressedUrl = nil
        self.videoCompressProgress = nil
        self.isVideoUploading = false
        self.submitError = nil
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
        avatarUploadEpoch = 0
        picUploadTasks = []
        localVideoOriginalUrl = nil
        localVideoCompressedUrl = nil
        videoCompressProgress = nil
        videoCompressEpoch = 0
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
            // 2026-07-16 修:submit 成功后 nav path 必须 reset。restricted resubmit flow submit 成功后
            // 不走 logout(直接 applyLogin userType=2 切 MainTabView),shared path 残留 [basicInfo,
            // required, videoRecord, videoPreview]。若之后审核态又变 restricted (sysMsg 58 reject)
            // 再进 MineRestrictedView → NavigationStack 从 shared path 恢复直接跳到 videoPreview。
            RegisterPathHolder.shared.reset()
        } catch let e as APIError {
            // 2026-07-12 修：APIError code=-1 是 iOS 内部客户端错误（envelope 解析失败——服务端空 body / 非 JSON / gateway 崩溃）
            // 而非后端业务码；e.message 是内部化文案 "Server response error"，用户看到不 actionable
            // 换成友好 retry 文案，对齐 H5 拦截器 line 133-152 error 分支的 status-mapped 友好文案精神
            if e.code == "-1" {
                submitError = L10n.Register.errorServerTemporary
            } else {
                submitError = e.message   // 后端业务 message 原文（如 1076 → "invite.code.not.exist"，对齐 H5 line 124-130）
            }
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

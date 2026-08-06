import Foundation

/// 派对房创建流程状态机（E-spec v5 · B 档降档，2026-07-10）。
///
/// **View 只读 @Published 铁律**（CLAUDE.md）：所有副作用/网络收敛进 Store，View 只 @ObservedObject 读。
/// 对齐 H5 用户端 `livechat-h5/src/views/party/create.vue`。
///
/// **字段与业务映射**：
/// - `roomName` (36 char cap) / `roomTagline` (36 char cap，H5 后端字段名 `greetingMessage`)
/// - `selectedLanguage`: 从 `languages` 中选；默认 `languages[0]`（H5 create.vue:44）
/// - `selectedTemplate`: 从 `templates` 选；默认 `templates.first`（Unlock 态才可选）；Lock 态 tap 弹 toast
/// - `mode`: 1=Voice / 2=Live+Voice（H5 apiGetRoomTempList type 参数）
/// - `userLevel`: 用户当前段位（判 Lock/Unlock）；MVP 从外部注入，本 Store 不管持久化
@MainActor
final class PartyCreateStore: ObservableObject {

    // MARK: - 输入字段（用户编辑）

    /// ⚠️ maxlength 校验由 View 层 `.onChange(of:)` 拦截（`@Published + didSet` 内递归赋值在 SwiftUI 里
    /// 不生效——setter 走完后 SwiftUI 已 render 一次超长值，用户能看到"超上限仍可继续输入"效果）
    @Published var roomName: String = ""
    @Published var roomTagline: String = ""

    @Published var selectedLanguage: PartyLanguage?
    @Published private(set) var selectedTemplate: PartyRoomTemplate?

    /// 头像上传后的 CDN URL；提交 createRoom 时传给 `roomAvatar` 字段
    /// v7：无本地上传时降级 fallback 到 `defaultAvatarUrl`（用户登录头像 mine.icon）
    @Published private(set) var uploadedAvatarUrl: String? = nil
    @Published private(set) var isUploadingAvatar: Bool = false
    @Published private(set) var uploadError: String = ""

    /// 用户当前登录头像（AnchorInfoStore.mine.icon）；View 层显示 + submit 时兜底
    let defaultAvatarUrl: String?

    // MARK: - Mode picker 状态

    /// 1=Voice / 2=Live+Voice（对齐 H5 type 参数）
    /// v6.1：切换 tab **只切 UI 不重拉**（两 mode list 同 loadInitial 一次性并发拉），
    /// 直接从 `templatesByMode` 缓存读取 + 切 selectedTemplate 到该 mode 下第一张
    @Published private(set) var mode: Int = 2 {
        didSet {
            guard mode != oldValue else { return }
            guard mode == Self.modeVoice || mode == Self.modeLiveVoice else {
                AppLogger.party.notice("[PartyCreate] ignored unknown template mode=\(self.mode, privacy: .public)")
                mode = canUsePartyVideo ? oldValue : Self.modeVoice
                return
            }
            guard !isApplyingPartyVideoRestriction else { return }
            guard canUsePartyVideo || mode != Self.modeLiveVoice else {
                AppLogger.party.notice("[PartyCreate] rejected live+voice mode for Party-only account")
                enforceVoiceOnlyMode()
                return
            }
            // 切 selectedTemplate 到新 mode 下**过 filter 的第一张**（缓存已就绪时无 loading，未就绪时走 loadInitial 补拉）
            selectTemplateForCurrentMode(loadIfMissing: true)
        }
    }

    /// 按 mode 缓存的模板列表（v6.1）
    @Published private(set) var templatesByMode: [Int: [PartyRoomTemplate]] = [:]
    @Published private(set) var templatesLoading: Bool = false
    @Published private(set) var templatesError: String = ""

    /// 当前 mode 下的模板列表（View 层用）
    /// 有效模板：`PartyRoomTemplate.hasValidDisplay`（id>0 + coverImage 或 fallback asset 命中）
    var templates: [PartyRoomTemplate] {
        visibleTemplates(for: mode)
    }

    // MARK: - Language picker 状态

    @Published private(set) var languages: [PartyLanguage] = []
    @Published private(set) var languagesLoading: Bool = false

    // MARK: - Background picker 状态（v7 对齐安卓）

    @Published private(set) var backgrounds: [PartyBackground] = []
    @Published private(set) var backgroundsLoading: Bool = false
    @Published var selectedBackground: PartyBackground?

    // MARK: - 提交状态

    @Published private(set) var isSubmitting: Bool = false
    @Published private(set) var submitError: String = ""

    /// 提交成功后 View 用来跳转到 PartyRoomView 的 roomId；nil 表示未提交或提交失败
    @Published private(set) var createdRoomId: String? = nil

    // MARK: - 用户段位（外部注入，判 Lock/Unlock）

    let userLevel: Int

    // MARK: - Const

    static let maxNameLength = 36
    static let maxTaglineLength = 36
    static let modeVoice = 1
    static let modeLiveVoice = 2

    // MARK: - 依赖

    private let service: PartyCreateService
    /// HilyTests 不编译 `SelfPermissionBridge+Shared.swift`，故通过 closure 注入生产权限快照。
    /// 生产实现仍直接复用 `.canPartyVideoSnapshot`；单测可覆盖 107 的拒绝路径。
    private let partyVideoCapabilityProvider: @MainActor () -> Bool
    private var isApplyingPartyVideoRestriction = false

    let taglineLengthLimit: Int

    var canUseVideoTemplates: Bool { canUsePartyVideo }

    private var canUsePartyVideo: Bool { partyVideoCapabilityProvider() }

    // MARK: - init

    init(
        service: PartyCreateService,
        defaultName: String = "",
        defaultTagline: String = "",
        defaultAvatarUrl: String? = nil,
        userLevel: Int = 0,
        taglineLengthLimit: Int = PartyCreateStore.maxTaglineLength,
        partyVideoCapabilityProvider: (@MainActor () -> Bool)? = nil
    ) {
        self.service = service
        // Default arguments are evaluated outside this actor; resolve the production provider here instead.
        self.partyVideoCapabilityProvider = partyVideoCapabilityProvider ?? Self.defaultCanUsePartyVideo
        self.userLevel = userLevel
        self.taglineLengthLimit = taglineLengthLimit
        self.defaultAvatarUrl = defaultAvatarUrl
        self.roomName = defaultName
        self.roomTagline = defaultTagline
        if !canUsePartyVideo {
            mode = Self.modeVoice
        }
    }

    // MARK: - Load 触发（View onAppear 调）

    /// 首次进入创房页时拉模板、语言和背景图。Party-only 账号只拉语音模板，
    /// 避免把 Live+Voice 模板下载进客户端缓存。
    func loadInitial() async {
        guard canUsePartyVideo else {
            enforceVoiceOnlyMode(loadVoiceTemplateIfNeeded: false)
            async let voice: () = loadTemplates(for: Self.modeVoice)
            async let l: () = loadLanguages()
            async let b: () = loadBackgrounds()
            _ = await (voice, l, b)
            return
        }
        async let voice: () = loadTemplates(for: Self.modeVoice)
        async let liveVoice: () = loadTemplates(for: Self.modeLiveVoice)
        async let l: () = loadLanguages()
        async let b: () = loadBackgrounds()
        _ = await (voice, liveVoice, l, b)
    }

    /// 拉背景图列表（安卓 loadData 第 3 项，首张自动选中）
    func loadBackgrounds() async {
        guard backgrounds.isEmpty else { return }
        backgroundsLoading = true
        defer { backgroundsLoading = false }
        do {
            let list = try await service.fetchBackgrounds()
            AppLogger.party.info("[PartyCreate] loadBackgrounds ok count=\(list.count, privacy: .public)")
            backgrounds = list
            // 首张自动选中（对齐安卓）
            if selectedBackground == nil { selectedBackground = list.first }
        } catch is CancellationError {
            return
        } catch {
            // v7.5：从静默降级改为 log 记录（原静默让用户"backgrounds picker 空态"无法排查）
            AppLogger.party.error("[PartyCreate] loadBackgrounds failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 权限校验（对齐安卓 PartyFragment 点击 Create 时 gate）
    /// 返回 canCreateRoom；失败时保守 return true（不阻塞用户）
    func checkCreatePermission() async -> Bool {
        do {
            let cond = try await service.fetchCreateConditions()
            return cond.canCreateRoom
        } catch {
            return true
        }
    }

    /// 拉某个 mode 的模板；缓存到 `templatesByMode[mode]`；仅切到当前 mode 时更新 selectedTemplate
    func loadTemplates(for targetMode: Int) async {
        guard targetMode == Self.modeVoice || targetMode == Self.modeLiveVoice else {
            AppLogger.party.notice("[PartyCreate] ignored template request for unknown mode=\(targetMode, privacy: .public)")
            return
        }
        guard targetMode != Self.modeLiveVoice || canUsePartyVideo else {
            AppLogger.party.notice("[PartyCreate] skipped live+voice template request for Party-only account")
            enforceVoiceOnlyMode(loadVoiceTemplateIfNeeded: false)
            return
        }
        // 仅当前 mode 切 loading 视觉；后台预拉不干扰 UI
        let isCurrent = targetMode == mode
        if isCurrent {
            templatesLoading = true
            templatesError = ""
        }
        defer {
            if isCurrent { templatesLoading = false }
        }
        do {
            let list = try await service.fetchTemplates(type: targetMode)
            // 请求在飞期间权限可被服务端改为 107；此时不得把已返回的视频模板写入缓存。
            guard targetMode != Self.modeLiveVoice || canUsePartyVideo else {
                AppLogger.party.notice("[PartyCreate] dropped live+voice templates after Party-only permission change")
                enforceVoiceOnlyMode(loadVoiceTemplateIfNeeded: false)
                return
            }
            templatesByMode[targetMode] = list
            // v6：全部可选，默认选第一张（仅当前 mode）
            // 用 filter 后的有效 list 判 selectedTemplate 归属 —— 防 selectedTemplate 指向被 filter
            // 剔除的空占位 template，UI 侧 templates 里没它但 canSubmit 依然 true
            if isCurrent { selectTemplateForCurrentMode(loadIfMissing: false) }
        } catch is CancellationError {
            return
        } catch {
            if isCurrent { templatesError = error.localizedDescription }
        }
    }

    func loadLanguages() async {
        guard languages.isEmpty else { return }
        languagesLoading = true
        defer { languagesLoading = false }
        do {
            let list = try await service.fetchLanguages()
            // H5 前端插首项 {languageName:'All', languageCode:''} 是用户端筛选用途；
            // 创房时**默认选 list[0]**（即真正的第一门语言，非 All）
            languages = list
            if selectedLanguage == nil { selectedLanguage = list.first }
        } catch is CancellationError {
            return
        } catch {
            // 语言列表失败静默降级——默认选 nil，View 显示占位
        }
    }

    // MARK: - Selection

    /// 模板 tap 处理：v6（2026-07-10）**对齐安卓：所有模板都可选，无等级门槛**。
    /// Party-only 账号只能选择已由语音接口返回且不含视频位的模板。
    @discardableResult
    func selectTemplate(_ template: PartyRoomTemplate, for targetMode: Int? = nil) -> Bool {
        let selectedMode = targetMode ?? mode
        guard canUsePartyVideo || isAllowedVoiceTemplate(template, for: selectedMode) else {
            AppLogger.party.notice("[PartyCreate] rejected non-voice template tempId=\(template.id, privacy: .public)")
            return false
        }
        selectedTemplate = template
        return true
    }

    /// 由 View 在 `SelfPermissionBridge` 的 UI 快照变更后调用，收敛已打开 picker 的状态。
    /// 普通账号从启动期 deny-default 变为允许后补拉 Live+Voice，保留用户当前语音选择。
    func refreshPartyVideoCapability() {
        guard canUsePartyVideo else {
            enforceVoiceOnlyMode()
            return
        }
        guard templatesByMode[Self.modeLiveVoice] == nil else { return }
        Task { await loadTemplates(for: Self.modeLiveVoice) }
    }

    /// View 不直接写 mode，避免通过 Binding 或 sheet 回调绕开 Party-only 限制。
    @discardableResult
    func selectMode(_ targetMode: Int) -> Bool {
        guard targetMode == Self.modeVoice || targetMode == Self.modeLiveVoice else {
            AppLogger.party.notice("[PartyCreate] rejected unknown template mode=\(targetMode, privacy: .public)")
            return false
        }
        guard canUsePartyVideo || targetMode != Self.modeLiveVoice else {
            AppLogger.party.notice("[PartyCreate] rejected live+voice mode for Party-only account")
            enforceVoiceOnlyMode()
            return false
        }
        mode = targetMode
        return true
    }

    // MARK: - Submit

    /// 提交条件：房名 + tagline + language + template 4 字段；头像上传中禁提交
    /// v7.5 反悔：**背景改 optional**（对齐 H5 create.vue:267 `bgImgId: selectedBg.value?.id`
    /// optional chaining，后端 nil 时用 default） —— 修复"backgrounds API 拉不到就无法创房"死锁
    var canSubmit: Bool {
        !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !roomTagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedLanguage != nil
            && selectedTemplate.map(isTemplateAllowedForSubmission) == true
            && !isSubmitting
            && !isUploadingAvatar
    }

    /// canSubmit=false 时缺失字段的 L10n hint —— UI 层 disable Create 按钮下方展示，
    /// 帮用户定位缺什么（v7.5 去掉 needBackground 分支，对齐 canSubmit）
    var missingFieldHint: String? {
        if roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.Party.createHintNeedName
        }
        if roomTagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.Party.createHintNeedTagline
        }
        if selectedLanguage == nil { return L10n.Party.createHintNeedLanguage }
        if selectedTemplate.map(isTemplateAllowedForSubmission) != true {
            return L10n.Party.createHintNeedTemplate
        }
        return nil
    }

    func submit() async {
        guard let lang = selectedLanguage, let temp = selectedTemplate else { return }
        guard isTemplateAllowedForSubmission(temp) else {
            AppLogger.party.notice("[PartyCreate] submit rejected for non-voice template tempId=\(temp.id, privacy: .public)")
            return
        }
        guard canSubmit else { return }
        isSubmitting = true
        submitError = ""
        defer { isSubmitting = false }
        // v7 对齐安卓：本地上传优先，否则 fallback 到登录默认头像
        let avatarUrl = uploadedAvatarUrl ?? defaultAvatarUrl
        do {
            let info = try await service.createRoom(
                roomName: roomName.trimmingCharacters(in: .whitespacesAndNewlines),
                greetingMessage: roomTagline.trimmingCharacters(in: .whitespacesAndNewlines),
                roomLanguage: lang.languageCode,
                roomTempId: temp.id,
                roomAvatar: avatarUrl,
                bgImgId: selectedBackground?.id
            )
            guard let id = info.id, !id.isEmpty else {
                submitError = "createErrorNoRoomId"
                PartyAnalytics.track(
                    "create_partyRoom_click",
                    properties: [
                        "result": "fail",
                        "modeNum": temp.id,
                    ]
                )
                return
            }
            createdRoomId = id
            PartyAnalytics.track(
                "create_partyRoom_click",
                properties: [
                    "roomId": id,
                    "result": "success",
                    "modeNum": temp.id,
                ]
            )
        } catch is CancellationError {
            return
        } catch let fake as PartyCreateFakeError {
            switch fake {
            case .networkError: submitError = "network"
            case .businessError(let code, let msg): submitError = "\(code):\(msg)"
            }
            PartyAnalytics.track(
                "create_partyRoom_click",
                properties: ["result": "fail", "modeNum": temp.id]
            )
        } catch {
            submitError = error.localizedDescription
            PartyAnalytics.track(
                "create_partyRoom_click",
                properties: ["result": "fail", "modeNum": temp.id]
            )
        }
    }

    /// View 消费 createdRoomId 触发 navigation 后清 —— 避免重复触发
    func clearCreatedRoomId() {
        createdRoomId = nil
    }

    /// View 层 toast 自清；submitError overlay 显示 3s 后调
    func clearSubmitError() {
        submitError = ""
    }

    // MARK: - Avatar upload

    /// View 层 PhotosPicker 拿到图片 Data 后调此方法：压缩 → OSS 上传 → 存 uploadedAvatarUrl
    /// - Note: 阻塞提交按钮直到上传完成，避免用户等待时 tap Create
    func uploadAvatar(rawData: Data) async {
        isUploadingAvatar = true
        uploadError = ""
        defer { isUploadingAvatar = false }
        #if HILY_TESTS
        // ImageUploader 依赖 OSS 上传栈，不在 test target 白名单；test 不覆盖此路径（走真机验证）
        uploadError = "upload not available in test target"
        #else
        do {
            let url = try await ImageUploader.shared.upload(rawData: rawData, preset: .avatar)
            uploadedAvatarUrl = url
        } catch {
            uploadError = error.localizedDescription
        }
        #endif
    }

    /// maxlength 拦截（View 层 onChange 调）：超上限 → 截断
    func trimNameIfNeeded() {
        if roomName.count > Self.maxNameLength {
            roomName = String(roomName.prefix(Self.maxNameLength))
        }
    }

    func trimTaglineIfNeeded() {
        if roomTagline.count > taglineLengthLimit {
            roomTagline = String(roomTagline.prefix(taglineLengthLimit))
        }
    }

    // MARK: - Party-only template guard

    /// 107 只能使用语音列表中实际下发的模板。未知 ID 一律拒绝，不能让手工构造的
    /// `PartyRoomTemplate` 绕过 UI 直接提交到 createRoom。
    private func isAllowedVoiceTemplate(_ template: PartyRoomTemplate, for targetMode: Int) -> Bool {
        guard targetMode == Self.modeVoice,
              templatesByMode[Self.modeVoice]?.contains(where: { $0.id == template.id }) == true,
              template.modeType != Self.modeLiveVoice,
              (template.videoSeatCount ?? 0) <= 0 else {
            return false
        }
        return template.hasValidDisplay
    }

    private func isTemplateAllowedForSubmission(_ template: PartyRoomTemplate) -> Bool {
        canUsePartyVideo || isAllowedVoiceTemplate(template, for: mode)
    }

    /// 给 View 层和 mode 切换复用的可见模板集合，避免从原始 cache 直接读到 107 禁止的内容。
    func visibleTemplates(for targetMode: Int) -> [PartyRoomTemplate] {
        guard targetMode == Self.modeVoice || targetMode == Self.modeLiveVoice,
              canUsePartyVideo || targetMode == Self.modeVoice else {
            return []
        }
        return (templatesByMode[targetMode] ?? []).filter { template in
            template.hasValidDisplay
                && (canUsePartyVideo || isAllowedVoiceTemplate(template, for: targetMode))
        }
    }

    private func enforceVoiceOnlyMode(loadVoiceTemplateIfNeeded: Bool = true) {
        guard !canUsePartyVideo else { return }
        templatesByMode.removeValue(forKey: Self.modeLiveVoice)
        if mode != Self.modeVoice {
            isApplyingPartyVideoRestriction = true
            mode = Self.modeVoice
            isApplyingPartyVideoRestriction = false
        }
        selectTemplateForCurrentMode(loadIfMissing: loadVoiceTemplateIfNeeded)
    }

    private func selectTemplateForCurrentMode(loadIfMissing: Bool) {
        let available = visibleTemplates(for: mode)
        if let current = selectedTemplate, !available.contains(where: { $0.id == current.id }) {
            selectedTemplate = available.first
        } else if selectedTemplate == nil {
            selectedTemplate = available.first
        }
        if available.isEmpty, loadIfMissing {
            Task { await loadTemplates(for: mode) }
        }
    }

    private static func defaultCanUsePartyVideo() -> Bool {
        #if HILY_TESTS
        // HilyTests 独立编译，不链接 SessionStore / SelfPermissionBridge+Shared。
        return true
        #else
        let permission = SelfPermissionBridge.shared
        if permission.isLoaded {
            return permission.canPartyVideoSnapshot
        }
        // Bridge 的 Session 订阅在一个 MainActor Task 中装配；首帧同样固定按 107 推导。
        guard SessionStore.shared.user != nil else { return false }
        return !UserPermissionMapping.blocked(for: UserTypeExperience.fixedUserType).contains(.partyVideo)
        #endif
    }
}

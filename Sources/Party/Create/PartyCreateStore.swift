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
    @Published var selectedTemplate: PartyRoomTemplate?

    /// 头像上传后的 CDN URL；提交 createRoom 时传给 `roomAvatar` 字段
    @Published private(set) var uploadedAvatarUrl: String? = nil
    @Published private(set) var isUploadingAvatar: Bool = false
    @Published private(set) var uploadError: String = ""

    // MARK: - Mode picker 状态

    /// 1=Voice / 2=Live+Voice（对齐 H5 type 参数）
    @Published var mode: Int = 2 {
        didSet {
            if mode != oldValue {
                Task { await loadTemplates() }
            }
        }
    }

    @Published private(set) var templates: [PartyRoomTemplate] = []
    @Published private(set) var templatesLoading: Bool = false
    @Published private(set) var templatesError: String = ""

    // MARK: - Language picker 状态

    @Published private(set) var languages: [PartyLanguage] = []
    @Published private(set) var languagesLoading: Bool = false

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

    // MARK: - init

    init(
        service: PartyCreateService,
        defaultName: String = "",
        defaultTagline: String = "",
        userLevel: Int = 0
    ) {
        self.service = service
        self.userLevel = userLevel
        self.roomName = defaultName
        self.roomTagline = defaultTagline
    }

    // MARK: - Load 触发（View onAppear 调）

    /// 首次进入创房页时拉模板 + 语言列表（并发）
    func loadInitial() async {
        async let t: () = loadTemplates()
        async let l: () = loadLanguages()
        _ = await (t, l)
    }

    func loadTemplates() async {
        templatesLoading = true
        templatesError = ""
        defer { templatesLoading = false }
        do {
            let list = try await service.fetchTemplates(type: mode)
            templates = list
            // 若已选模板不在新 list 中，重置到第一张 Unlock 的
            if let cur = selectedTemplate, !list.contains(where: { $0.id == cur.id }) {
                selectedTemplate = list.first(where: { isUnlocked($0) })
            } else if selectedTemplate == nil {
                selectedTemplate = list.first(where: { isUnlocked($0) })
            }
        } catch is CancellationError {
            return
        } catch {
            templatesError = error.localizedDescription
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

    /// 模板 tap 处理：Unlock 直接选中；Lock 触发 lockedTapError（View 消费显示 toast）
    /// 返回 nil 表示 Unlock 选中成功；返回非 nil 是 Lock 提示文案
    @discardableResult
    func selectTemplate(_ template: PartyRoomTemplate) -> String? {
        if isUnlocked(template) {
            selectedTemplate = template
            return nil
        }
        return lockedMessage(for: template)
    }

    /// 用户段位是否解锁该模板
    func isUnlocked(_ template: PartyRoomTemplate) -> Bool {
        guard let need = template.createRoomLevel, need > 0 else { return true }
        return userLevel >= need
    }

    /// Lock 模板 tap 时给 view 层的 toast 文案生成
    private func lockedMessage(for template: PartyRoomTemplate) -> String {
        // 对齐 H5 upLevel.vue:82：`Level X or above is required to use room mode`
        let need = template.createRoomLevel ?? 0
        return "Lv.\(need) required"
    }

    // MARK: - Submit

    /// 提交条件：房名 + tagline + language + template 都非空/nil；头像上传中禁提交
    var canSubmit: Bool {
        !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !roomTagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedLanguage != nil
            && selectedTemplate != nil
            && !isSubmitting
            && !isUploadingAvatar
    }

    func submit() async {
        guard canSubmit,
              let lang = selectedLanguage,
              let temp = selectedTemplate else { return }
        isSubmitting = true
        submitError = ""
        defer { isSubmitting = false }
        do {
            let info = try await service.createRoom(
                roomName: roomName.trimmingCharacters(in: .whitespacesAndNewlines),
                greetingMessage: roomTagline.trimmingCharacters(in: .whitespacesAndNewlines),
                roomLanguage: lang.languageCode,
                roomTempId: temp.id,
                roomAvatar: uploadedAvatarUrl
            )
            guard let id = info.id, !id.isEmpty else {
                submitError = "createErrorNoRoomId"
                return
            }
            createdRoomId = id
        } catch is CancellationError {
            return
        } catch let fake as PartyCreateFakeError {
            switch fake {
            case .networkError: submitError = "network"
            case .businessError(let code, let msg): submitError = "\(code):\(msg)"
            }
        } catch {
            submitError = error.localizedDescription
        }
    }

    /// View 消费 createdRoomId 触发 navigation 后清 —— 避免重复触发
    func clearCreatedRoomId() {
        createdRoomId = nil
    }

    // MARK: - Avatar upload

    /// View 层 PhotosPicker 拿到图片 Data 后调此方法：压缩 → OSS 上传 → 存 uploadedAvatarUrl
    /// - Note: 阻塞提交按钮直到上传完成，避免用户等待时 tap Create
    func uploadAvatar(rawData: Data) async {
        isUploadingAvatar = true
        uploadError = ""
        defer { isUploadingAvatar = false }
        do {
            let url = try await ImageUploader.shared.upload(rawData: rawData, preset: .avatar)
            uploadedAvatarUrl = url
        } catch {
            uploadError = error.localizedDescription
        }
    }

    /// maxlength 拦截（View 层 onChange 调）：超上限 → 截断
    func trimNameIfNeeded() {
        if roomName.count > Self.maxNameLength {
            roomName = String(roomName.prefix(Self.maxNameLength))
        }
    }

    func trimTaglineIfNeeded() {
        if roomTagline.count > Self.maxTaglineLength {
            roomTagline = String(roomTagline.prefix(Self.maxTaglineLength))
        }
    }
}

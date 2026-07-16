import Foundation

/// 保存成功后回传给上层的 diff 快照（nil 表示未变化，非 nil 表示已实际保存的新值）。
/// 上层 PartyRoomView 用它调 `PartyStore.applyRoomSettingsChanges(...)` 同步 `roomInfo`。
struct PartyRoomSettingsSnapshot: Equatable {
    let roomName: String?
    let tagline: String?
    let languageCode: String?
    let avatarUrl: String?

    var hasAnyChange: Bool {
        roomName != nil || tagline != nil || languageCode != nil || avatarUrl != nil
    }
}

/// 派对房设置页状态机（房主编辑房间信息）。
///
/// **对齐 H5 create.vue 编辑态**：
/// - Room name / Tagline / Avatar / Language 通过 `apiPartyUpdateRoom` diff 保存
/// - Room Background 是**独立 setter** `apiSetPartyBgImage`（选完 sheet 就即时保存，不进 save diff）
/// - Admin 管理由 `PartyAdminStore` 独立处理
///
/// **保存策略**：只传变更 diff（对齐 H5 create.vue:296-302）
@MainActor
final class PartyRoomSettingsStore: ObservableObject {

    // MARK: - 输入字段

    @Published var roomName: String = "" {
        didSet {
            if roomName.count > Self.maxNameLength {
                roomName = String(roomName.prefix(Self.maxNameLength))
            }
        }
    }

    @Published var roomTagline: String = "" {
        didSet {
            if roomTagline.count > Self.maxTaglineLength {
                roomTagline = String(roomTagline.prefix(Self.maxTaglineLength))
            }
        }
    }

    @Published var selectedLanguage: PartyLanguage?
    @Published var selectedBackground: PartyBackground?

    // MARK: - 头像上传

    @Published private(set) var uploadedAvatarUrl: String? = nil
    @Published private(set) var isUploadingAvatar: Bool = false
    @Published private(set) var uploadError: String = ""

    // MARK: - 语言 / 背景 picker 数据

    @Published private(set) var languages: [PartyLanguage] = []
    @Published private(set) var backgrounds: [PartyBackground] = []

    // MARK: - 保存状态

    @Published private(set) var isSaving: Bool = false
    @Published private(set) var saveError: String = ""
    /// 保存成功 → true；View 层消费触发 dismiss + toast
    @Published private(set) var didSaveSuccessfully: Bool = false

    // MARK: - 只读原始值（用于 diff 判断）

    let roomId: String
    let originalRoomName: String
    let originalTagline: String
    let originalLanguageCode: String
    let originalAvatarUrl: String?
    let originalBackgroundId: Int?

    // MARK: - Const

    static let maxNameLength = 36
    static let maxTaglineLength = 36

    // MARK: - 依赖

    private let service: PartyRoomSettingsService

    /// v18：selectBackground 串行化，防用户快速 tap X→Y 导致 setBackground 请求乱序 →
    /// 本地 currentRoomBackground / selectedBackground / 服务器状态三方分裂。
    /// 有 in-flight 时新 tap 静默丢弃（View 层已通过 selectedBackground 乐观 UI 立即反馈）。
    private var isSelectingBackground: Bool = false

    // MARK: - Init

    init(
        roomId: String,
        roomName: String,
        tagline: String,
        languageCode: String,
        avatarUrl: String?,
        backgroundId: Int?,
        service: PartyRoomSettingsService = PartyRoomSettingsServiceLive()
    ) {
        self.roomId = roomId
        self.service = service
        self.originalRoomName = roomName
        self.originalTagline = tagline
        self.originalLanguageCode = languageCode
        self.originalAvatarUrl = avatarUrl
        self.originalBackgroundId = backgroundId

        self.roomName = roomName
        self.roomTagline = tagline
    }

    // MARK: - Load

    /// 拉语言 + 背景列表 + 当前房间 selected 背景（对齐 H5 编辑态 loadData）
    func loadInitial() async {
        async let l: () = loadLanguages()
        async let b: () = loadBackgrounds()
        async let bg: () = loadCurrentBackground()
        _ = await (l, b, bg)
    }

    private func loadLanguages() async {
        guard languages.isEmpty else { return }
        do {
            let list = try await service.fetchLanguages()
            languages = list
            // 匹配 originalLanguageCode 到 list 里的 PartyLanguage
            if selectedLanguage == nil {
                selectedLanguage = list.first(where: { $0.languageCode == originalLanguageCode })
                                ?? list.first
            }
        } catch {}
    }

    private func loadBackgrounds() async {
        guard backgrounds.isEmpty else { return }
        do {
            backgrounds = try await service.fetchBackgrounds()
        } catch {}
    }

    private func loadCurrentBackground() async {
        // 若 init 时已知 backgroundId，从 backgrounds 匹配即可；未知则拉 getRoomBgImage
        if let id = originalBackgroundId,
           let cur = backgrounds.first(where: { $0.id == id }) {
            selectedBackground = cur
            return
        }
        do {
            let cur = try await service.fetchCurrentBackground(roomId: roomId)
            selectedBackground = cur
        } catch {}
    }

    // MARK: - Actions

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

    /// 用户选新背景 → 即时调 setBgImages（对齐 H5 编辑态 apiSetPartyBgImage 独立 setter）
    ///
    /// **v17 真根因修复**：接口成功后必须回流完整 `bg` 到 `PartyStore.currentRoomBackground`
    /// —— 否则主房间视图（PartyRoomView）看到的仍是 loadCurrentRoomBackground 从
    /// `getRoomBgImage` 拉到的 id-only 对象（bigImgUrl=nil），永远走 DEFAULT_BG 静态兜底。
    /// 对齐 H5 用户端 `create.vue:200-203` 精神：接口成功后前端直接把手里已有的完整对象塞回。
    func selectBackground(_ bg: PartyBackground) async {
        // 未变化不发接口
        guard selectedBackground?.id != bg.id else { return }
        // v18：in-flight guard 防 rapid-tap 三方分裂（本地 vs UI vs 服务器）
        guard !isSelectingBackground else {
            AppLogger.party.notice("[PartyRoomSettings] selectBackground drop: in-flight (tapped=\(bg.id, privacy: .public))")
            return
        }
        isSelectingBackground = true
        defer { isSelectingBackground = false }
        // 乐观 update UI
        let prev = selectedBackground
        selectedBackground = bg
        do {
            try await service.setBackground(roomId: roomId, bgImgId: bg.id)
            // 回流 PartyStore 让 PartyRoomView 立即换背景（动图 URL 从 bg.bigImgUrl 直接可用）
            // PartyStore 不在 HilyTests 白名单，test target 编译时用 stub（bg 已通过 service.setBackground 到位）
            #if !HILY_TESTS
            PartyStore.shared.updateCurrentRoomBackground(bg)
            #endif
        } catch {
            // 失败回退
            selectedBackground = prev
            saveError = error.localizedDescription
        }
    }

    // MARK: - Save (Confirm)

    /// diff 检测：任一字段与原值不同即可保存
    var hasChanges: Bool {
        let curName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let curTag = roomTagline.trimmingCharacters(in: .whitespacesAndNewlines)
        let curLang = selectedLanguage?.languageCode ?? ""
        return curName != originalRoomName
            || curTag != originalTagline
            || curLang != originalLanguageCode
            || uploadedAvatarUrl != nil
    }

    /// 提交条件：字段非空 + 有变更 + 不在提交/上传中
    var canSave: Bool {
        !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !roomTagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedLanguage != nil
            && hasChanges
            && !isSaving
            && !isUploadingAvatar
    }

    func save() async {
        guard canSave else { return }
        isSaving = true
        saveError = ""
        defer { isSaving = false }

        let curName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let curTag = roomTagline.trimmingCharacters(in: .whitespacesAndNewlines)
        let curLang = selectedLanguage?.languageCode ?? ""

        // 仅传 diff（对齐 H5 create.vue:296-302）
        let diffName: String? = curName != originalRoomName ? curName : nil
        let diffTag: String? = curTag != originalTagline ? curTag : nil
        let diffLang: String? = curLang != originalLanguageCode ? curLang : nil
        let diffAvatar: String? = uploadedAvatarUrl   // 有本地新上传就传，否则 nil

        do {
            try await service.updateRoom(
                roomId: roomId,
                roomName: diffName,
                roomAvatar: diffAvatar,
                greetingMessage: diffTag,
                roomLanguage: diffLang
            )
            didSaveSuccessfully = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    func clearSaveError() { saveError = "" }
    func clearDidSaveSuccessfully() { didSaveSuccessfully = false }

    /// 保存成功后回传的 diff 快照。仅返回**实际保存的字段**（nil 表示未变化）。
    /// 与 `save()` 内的 diff 判断保持一致语义 —— 供 View 调 `onSaved(snapshot)` 通知上层。
    func savedDiffSnapshot() -> PartyRoomSettingsSnapshot {
        let curName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let curTag = roomTagline.trimmingCharacters(in: .whitespacesAndNewlines)
        let curLang = selectedLanguage?.languageCode ?? ""
        return PartyRoomSettingsSnapshot(
            roomName: curName != originalRoomName ? curName : nil,
            tagline: curTag != originalTagline ? curTag : nil,
            languageCode: curLang != originalLanguageCode ? curLang : nil,
            avatarUrl: uploadedAvatarUrl
        )
    }
}

import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "RouletteStore")

/// Roulette 状态机（对齐 H5 [liveRoulettePopup.vue](H5) 完整交互）
///
/// **首次引导标记**（对齐 H5 localStorage 按 userId scope）：
/// - UserDefaults key: `roulette.intro.shown.<userId>`
///
/// **草稿态双份**（对齐 H5 baseWheelSectorList + interactionList 双份）：
/// - `savedConfig`：服务端最新已保存态（enabled/price/sectors）
/// - `draftPrice` / `draftSectors`：编辑草稿；dirty 派生自 savedConfig 对比
///
/// **主按钮三态**（对齐 H5 L311-333）：
/// - `.finishEditing` if enabled && dirty
/// - `.enable`      if !enabled && draftSectors.count>=3 && draftPrice>0
/// - `.disabled`    其他
@MainActor
final class RouletteStore: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    enum MainButtonKind: Equatable {
        case disabled
        case enable
        case finishEditing
    }

    // MARK: - Published

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var savedConfig: RouletteConfig = .defaultConfig
    @Published var draftPrice: Int = 0
    @Published var draftSectors: [RouletteSector] = []
    @Published private(set) var presetItems: [RoulettePreset] = []
    @Published private(set) var isSaving: Bool = false
    /// 底部一次性 toast（2s 自消，view overlay 消费）
    @Published var toast: String?

    // MARK: - Deps

    private let service: RouletteServiceProtocol
    private let anchorUserId: String
    private let liveRoomId: String

    init(service: RouletteServiceProtocol = RouletteServiceReal(),
         anchorUserId: String, liveRoomId: String) {
        self.service = service
        self.anchorUserId = anchorUserId
        self.liveRoomId = liveRoomId
    }

    // MARK: - Derived

    /// 用户是否修改过草稿（对齐 H5 openAndChangeDataStatus）
    var isDirty: Bool {
        let savedSectorsKey = savedConfig.sectors.filter { !$0.isPlaceholder }
            .map { "\($0.presetId)|\($0.text)" }
        let draftSectorsKey = draftSectors.filter { !$0.isPlaceholder }
            .map { "\($0.presetId)|\($0.text)" }
        return draftPrice != savedConfig.price || savedSectorsKey != draftSectorsKey
    }

    /// 3 状态主按钮语义
    var mainButtonKind: MainButtonKind {
        let realSectors = draftSectors.filter { !$0.isPlaceholder }
        if savedConfig.enabled && isDirty { return .finishEditing }
        if !savedConfig.enabled && realSectors.count >= 3 && draftPrice > 0 { return .enable }
        return .disabled
    }

    /// Close Wheel 按钮是否显示（只有当前处于启用态才有）
    var closeButtonVisible: Bool { savedConfig.enabled }

    /// 用于中央转盘绘制：draft sectors 补齐到 4-8 项（不满 4 补占位，超 8 截断）
    /// 对齐 H5 baseWheelSectorList push placeholder 逻辑
    var displaySectors: [RouletteSector] {
        var arr = draftSectors.filter { !$0.isPlaceholder }
        while arr.count < 4 {
            arr.append(RouletteSector(presetId: "", text: L10n.liveRoomRouletteSectorsEmpty,
                                      isPlaceholder: true, id: "placeholder.\(arr.count)"))
        }
        return Array(arr.prefix(8))
    }

    // MARK: - 首次引导标记

    static func introShownKey(userId: String) -> String { "roulette.intro.shown.\(userId)" }

    var isIntroShown: Bool {
        UserDefaults.standard.bool(forKey: Self.introShownKey(userId: anchorUserId))
    }

    func markIntroShown() {
        UserDefaults.standard.set(true, forKey: Self.introShownKey(userId: anchorUserId))
    }

    // MARK: - 加载

    func loadIfNeeded() {
        guard state == .idle else { return }
        Task { await load() }
    }

    func retry() { Task { await load() } }

    private func load() async {
        state = .loading
        do {
            async let cfg = service.queryConfig(anchorUserId: anchorUserId)
            async let presets = service.presetTexts()
            let config = try await cfg
            let items = (try? await presets)?.items ?? []
            applyLoaded(config: config, presets: items)
        } catch {
            logger.warning("Roulette load failed: \(String(describing: error), privacy: .private)")
            state = .error(String(describing: error))
        }
    }

    private func applyLoaded(config: RouletteConfig, presets: [RoulettePreset]) {
        savedConfig = config
        draftPrice = config.price
        draftSectors = config.sectors.filter { !$0.isPlaceholder }
        presetItems = presets
        state = .loaded
    }

    // MARK: - 编辑 draft（对齐 H5 chooseItem / delItem / handleBlur）

    /// 追加手动输入项（对齐 H5 handleBlur push {presetId:'', text}）
    /// - 20 字截断由 view 层 TextField 做（对齐 H5 maxlength=20）
    func appendManualSector(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, draftSectors.count < 8 else { return }
        draftSectors.append(RouletteSector(presetId: "", text: String(trimmed.prefix(20))))
    }

    /// 删除已选项（对齐 H5 delItem index）
    func removeSector(at index: Int) {
        guard draftSectors.indices.contains(index) else { return }
        draftSectors.remove(at: index)
    }

    /// 预设项 toggle（对齐 H5 chooseItem: presetId 已存在则移除，否则追加）
    func togglePreset(_ preset: RoulettePreset) {
        if let idx = draftSectors.firstIndex(where: { $0.presetId == preset.id }) {
            draftSectors.remove(at: idx)
        } else if draftSectors.count < 8 {
            draftSectors.append(RouletteSector(presetId: preset.id, text: preset.text))
        }
    }

    // MARK: - 保存 / 状态切换（对齐 H5 saveBtn / enableWheelBtn / closeWheelBtn / finishEditingBtn）

    /// 编辑子 sheet 的 Confirm（H5 saveBtn）—— 保存当前 draft，不改 enabled 状态
    func confirmEdit() async {
        await save(desiredEnabled: savedConfig.enabled, successToast: nil)
    }

    /// 主按钮 Enable Wheel（H5 enableWheelBtn）—— 保存 + enabled=true + toast started
    func enableWheel() async {
        guard draftPrice > 0 else {
            toast = L10n.liveRoomRouletteToastEnterPrice
            scheduleToastClear()
            return
        }
        await save(desiredEnabled: true, successToast: L10n.liveRoomRouletteToastStarted)
    }

    /// 主按钮 Finish Editing（H5 finishEditingBtn）—— 已启用态下保存 draft，保持 enabled=true
    func finishEditing() async {
        guard draftPrice > 0 else {
            toast = L10n.liveRoomRouletteToastEnterPrice
            scheduleToastClear()
            return
        }
        await save(desiredEnabled: true, successToast: L10n.liveRoomRouletteToastStarted)
    }

    /// Close Wheel（H5 closeWheelBtn）—— 走 changeStatus + toast stopped，不改 draft
    func closeWheel() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let toSubmit = currentSubmitConfig(enabled: false)
        do {
            try await service.changeStatus(config: toSubmit, enabled: false, liveRoomId: liveRoomId)
            savedConfig = RouletteConfig(enabled: false, price: toSubmit.price, sectors: toSubmit.sectors)
            toast = L10n.liveRoomRouletteToastStopped
            scheduleToastClear()
        } catch {
            logger.warning("Roulette closeWheel failed: \(String(describing: error), privacy: .private)")
            toast = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            scheduleToastClear()
        }
    }

    // MARK: - private

    private func currentSubmitConfig(enabled: Bool) -> RouletteConfig {
        RouletteConfig(
            enabled: enabled,
            price: draftPrice,
            sectors: draftSectors.filter { !$0.isPlaceholder }
        )
    }

    private func save(desiredEnabled: Bool, successToast: String?) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let toSubmit = currentSubmitConfig(enabled: desiredEnabled)
        do {
            let saved = try await service.saveConfig(toSubmit, liveRoomId: liveRoomId)
            // 后端可能回填 sectors（addWheelConfig response.wheelSectors）；有则采用，无则用提交值
            let finalSectors = saved.sectors.isEmpty ? toSubmit.sectors : saved.sectors
            savedConfig = RouletteConfig(enabled: desiredEnabled, price: toSubmit.price, sectors: finalSectors)
            draftSectors = finalSectors
            if let msg = successToast {
                toast = msg
                scheduleToastClear()
            }
        } catch {
            logger.warning("Roulette save failed: \(String(describing: error), privacy: .private)")
            toast = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            scheduleToastClear()
        }
    }

    private func scheduleToastClear() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.toast = nil
        }
    }
}

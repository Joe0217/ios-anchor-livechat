import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "RouletteStore")

/// Roulette 状态机（对齐 H5 [liveRoulettePopup.vue](H5) 完整交互）
///
/// **首次引导标记**（对齐 H5 localStorage 按 userId scope）：
/// - UserDefaults key: `roulette.intro.shown.<userId>`
///
/// **草稿态双份**（对齐 H5 baseWheelSectorList + interactionList 双份）：
/// - `savedConfig`：服务端最新已保存态（enabled/price/sectors）
/// - `draftPrice` / `draftSectors`：编辑草稿
///
/// **主按钮三态**（对齐 H5 L311-333）：
/// - `.finishEditing` if enabled && 曾修改过草稿（H5 sticky `openAndChangeDataStatus`）
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
    @Published private(set) var draftPrice: Int = 0
    @Published private(set) var draftSectors: [RouletteSector] = []
    @Published private(set) var hasEnabledEditChanges: Bool = false
    @Published private(set) var presetItems: [RoulettePreset] = []
    @Published private(set) var isSaving: Bool = false
    /// 底部一次性 toast（2s 自消，view overlay 消费）
    @Published var toast: String?

    // MARK: - Deps

    private let service: RouletteServiceProtocol
    private let anchorUserId: String
    private let liveRoomId: String
    private var toastClearTask: Task<Void, Never>?

    init(service: RouletteServiceProtocol = RouletteServiceReal(),
         anchorUserId: String, liveRoomId: String) {
        self.service = service
        self.anchorUserId = anchorUserId
        self.liveRoomId = liveRoomId
    }

    // MARK: - Derived

    /// 当前草稿是否与服务端保存态不同。仅用于诊断；主按钮使用 H5 的 sticky 修改标记。
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
        if savedConfig.enabled && hasEnabledEditChanges { return .finishEditing }
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
        hasEnabledEditChanges = false
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
        markEnabledEditChanged()
    }

    /// 删除已选项（对齐 H5 delItem index）
    func removeSector(at index: Int) {
        guard draftSectors.indices.contains(index) else { return }
        draftSectors.remove(at: index)
        markEnabledEditChanged()
    }

    /// 预设项 toggle（对齐 H5 chooseItem: presetId 已存在则移除，否则追加）
    func togglePreset(_ preset: RoulettePreset) {
        if let idx = draftSectors.firstIndex(where: { $0.presetId == preset.id }) {
            draftSectors.remove(at: idx)
            markEnabledEditChanged()
        } else if draftSectors.count < 8 {
            draftSectors.append(RouletteSector(presetId: preset.id, text: preset.text))
            markEnabledEditChanged()
        }
    }

    /// 对齐 H5 `handleChange`：开启态价格一旦发生变化，完成编辑按钮保持可见直到外层关闭。
    func updateDraftPrice(_ price: Int) {
        if draftPrice != price {
            markEnabledEditChanged()
        }
        draftPrice = price
    }

    // MARK: - 保存 / 状态切换（对齐 H5 saveBtn / enableWheelBtn / closeWheelBtn / finishEditingBtn）

    /// 编辑子 sheet 的 Confirm（H5 saveBtn）—— 成功才允许关闭编辑页。
    @discardableResult
    func confirmEdit() async -> Bool {
        await save(desiredEnabled: savedConfig.enabled, successToast: nil)
    }

    /// 主按钮 Enable Wheel（H5 enableWheelBtn）—— 保存 + enabled=true + toast started
    @discardableResult
    func enableWheel() async -> Bool {
        guard requirePrice() else { return false }
        return await save(desiredEnabled: true, successToast: L10n.liveRoomRouletteToastStarted)
    }

    /// 主按钮 Finish Editing（H5 finishEditingBtn）—— 已启用态下保存 draft，保持 enabled=true
    @discardableResult
    func finishEditing() async -> Bool {
        guard requirePrice() else { return false }
        return await save(desiredEnabled: true, successToast: L10n.liveRoomRouletteToastStarted)
    }

    /// Close Wheel（H5 closeWheelBtn）—— 走 changeStatus + toast stopped，不改 draft
    @discardableResult
    func closeWheel() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        let toSubmit = currentSubmitConfig(enabled: false)
        do {
            try await service.changeStatus(config: toSubmit, enabled: false, liveRoomId: liveRoomId)
            savedConfig = RouletteConfig(enabled: false, price: toSubmit.price, sectors: toSubmit.sectors)
            showToast(L10n.liveRoomRouletteToastStopped)
            return true
        } catch {
            logger.warning("Roulette closeWheel failed: \(String(describing: error), privacy: .private)")
            showToast((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return false
        }
    }

    /// H5 `editWheelBtn` / Enable / Finish Editing 的共同价格门禁。
    func requirePrice() -> Bool {
        guard draftPrice > 0 else {
            showToast(L10n.liveRoomRouletteToastEnterPrice)
            return false
        }
        return true
    }

    /// H5 `editWheelBtn` 每次打开编辑页前都会重新读取服务器奖项。
    /// 价格输入是主页面本地草稿，不应被这次刷新覆盖。
    func reloadSectorsForEditing() async {
        guard !isSaving else { return }
        do {
            let config = try await service.queryConfig(anchorUserId: anchorUserId)
            savedConfig = config
            draftSectors = config.sectors.filter { !$0.isPlaceholder }
        } catch {
            // H5 查询失败仍允许进入编辑页，继续使用当前已加载的草稿。
            logger.warning("Roulette edit reload failed: \(String(describing: error), privacy: .private)")
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

    private func markEnabledEditChanged() {
        if savedConfig.enabled {
            hasEnabledEditChanges = true
        }
    }

    private func save(desiredEnabled: Bool, successToast: String?) async -> Bool {
        guard !isSaving else { return false }
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
                showToast(msg)
            }
            return true
        } catch {
            logger.warning("Roulette save failed: \(String(describing: error), privacy: .private)")
            showToast((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return false
        }
    }

    private func showToast(_ message: String) {
        toastClearTask?.cancel()
        toast = message
        toastClearTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.toast = nil
            self.toastClearTask = nil
        }
    }
}

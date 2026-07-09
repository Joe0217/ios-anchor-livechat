import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "RouletteStore")

/// Roulette 状态机（对齐 H5 liveRoulettePopup.vue + rpsIntroPopup.vue 组合逻辑）
///
/// **首次引导逻辑**（对齐 H5 localStorage 按 userId 标记）：
/// - iOS 侧用 UserDefaults key: `roulette.intro.shown.<userId>` 存 Bool
@MainActor
final class RouletteStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(RouletteConfig)
        case error(String)
    }

    @Published private(set) var state: LoadState = .idle
    @Published var draftConfig: RouletteConfig = .defaultConfig
    @Published private(set) var presetTexts: RoulettePresetTexts = .empty

    private let service: RouletteServiceProtocol
    private let anchorUserId: String
    private let liveRoomId: String

    init(service: RouletteServiceProtocol = RouletteServiceFakes(),
         anchorUserId: String, liveRoomId: String) {
        self.service = service
        self.anchorUserId = anchorUserId
        self.liveRoomId = liveRoomId
    }

    // MARK: - 首次引导标记（对齐 H5 localStorage 按 userId scope）

    static func introShownKey(userId: String) -> String { "roulette.intro.shown.\(userId)" }

    /// 已完成首次引导？
    var isIntroShown: Bool {
        UserDefaults.standard.bool(forKey: Self.introShownKey(userId: anchorUserId))
    }

    /// 标记首次引导完成（用户点"开始"按钮后调用）
    func markIntroShown() {
        UserDefaults.standard.set(true, forKey: Self.introShownKey(userId: anchorUserId))
    }

    // MARK: - 配置加载 / 保存

    func loadIfNeeded() {
        guard state == .idle else { return }
        Task { await load() }
    }

    private func load() async {
        state = .loading
        do {
            async let cfg = service.queryConfig(anchorUserId: anchorUserId)
            async let presets = service.presetTexts()
            let config = try await cfg
            presetTexts = try await presets
            draftConfig = config
            state = .loaded(config)
        } catch {
            logger.warning("Roulette load failed: \(String(describing: error), privacy: .private)")
            state = .error(String(describing: error))
        }
    }

    /// 切换启用开关（对齐 H5 changeWheelStatus 单接口）
    func toggleEnabled() {
        let newEnabled = !draftConfig.enabled
        draftConfig.enabled = newEnabled
        Task {
            do {
                try await service.changeStatus(enabled: newEnabled, liveRoomId: liveRoomId)
            } catch {
                logger.warning("Roulette changeStatus failed: \(String(describing: error), privacy: .private)")
                // rollback UI
                draftConfig.enabled = !newEnabled
            }
        }
    }

    /// 保存配置（sector 编辑完成后）
    func save() {
        let cfg = draftConfig
        Task {
            do {
                try await service.saveConfig(cfg, liveRoomId: liveRoomId)
                state = .loaded(cfg)
            } catch {
                logger.warning("Roulette save failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    func retry() { Task { await load() } }
}

import Foundation

/// 转盘奖项（对齐 H5 liveRoulettePopup.vue `wheelSectorList` / `addWheelSector`）
///
/// H5 数据结构：`{ presetId: Number | '' , text: string, delete?: boolean }`
/// - `presetId=""` → 用户手动输入项
/// - `presetId="1"..."N"` → 从 presetText 选中项
/// - `isPlaceholder=true` → 对齐 H5 `delete:true` 语义；显示时补齐 4-8 用，保存前 filter 掉
struct RouletteSector: Equatable, Identifiable {
    /// SwiftUI ForEach 用；presetId 空则用 uuid 兜底（对同一 sector 保持稳定）
    let id: String
    var presetId: String
    var text: String
    var isPlaceholder: Bool

    init(presetId: String, text: String, isPlaceholder: Bool = false, id: String? = nil) {
        self.presetId = presetId
        self.text = text
        self.isPlaceholder = isPlaceholder
        self.id = id ?? (presetId.isEmpty ? UUID().uuidString : presetId)
    }
}

/// queryPresetText 响应项（H5 tjItems）
struct RoulettePreset: Equatable, Identifiable {
    let id: String
    let text: String
}

/// 转盘配置（对齐 H5 wheel config）
struct RouletteConfig: Equatable {
    var enabled: Bool
    var price: Int
    var sectors: [RouletteSector]

    static let defaultConfig = RouletteConfig(enabled: false, price: 0, sectors: [])
}

/// H5 后端返回的预设文案（onMounted queryPresetText 拉取）
struct RoulettePresetTexts: Equatable {
    let items: [RoulettePreset]
    static let empty = RoulettePresetTexts(items: [])
}

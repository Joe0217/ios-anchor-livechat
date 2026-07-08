import Foundation

/// K spec §4.2/§4.3 参数元数据（H5 对齐版 2026-07-02）：
/// H5 是"参数图标选择 + 单顶部 slider" 交互 —— 每个 icon 对应一个参数，
/// 选中后顶部 slider 绑定该参数值。此表统一定义所有 25 个参数的 label / icon / 范围 / 读写。
///
/// **Recover** 是特殊 icon（每个 tab 第一位），点击时重置当前 tab 内所有参数到 defaults。
enum BeautyParamGroup {
    case skin  // 美肤 10 项 → H5 "Beauty Effects" tab
    case shape // 美型 15 项 → H5 "Face Shaping" tab
}

struct BeautyParamEntry: Identifiable, Hashable {
    /// 稳定 id（key）—— selectedParam 比较用
    let id: String
    /// UI 显示 label
    let label: String
    /// 图标名。isAssetIcon=true 时是 Assets.xcassets 里的 imageset 名（H5 官方 Mob 图标），
    /// false 时是 SF Symbol 名（iOS 独有的 4 项 shape 参数未在 H5 官方图标库里，用 SF Symbol 兜底）
    let icon: String
    let isAssetIcon: Bool
    /// UI 值范围（type1 = 0~100 / type2 = -50~50 / type3 = 0~100 磨皮）
    let range: ClosedRange<Double>
    let reflexType: ReflexType
    /// 从 BeautySettings 读取
    let get: (BeautySettings) -> Double
    /// 向 BeautySettings 写入
    let set: (inout BeautySettings, Double) -> Void

    // Hashable: 用 id 做唯一标识
    static func == (lhs: BeautyParamEntry, rhs: BeautyParamEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum BeautyParamCatalog {

    // MARK: - 美肤 10 项（对齐 H5 "Beauty Effects" tab；icon 全部走 H5 官方 Mob 图标）
    static let skinParams: [BeautyParamEntry] = [
        .init(id: "blur",       label: L10n.BeautySettings.paramBlur,       icon: "MobMopi", isAssetIcon: true,
              range: 0...100, reflexType: .type3,
              get: { $0.blur }, set: { $0.blur = $1 }),
        .init(id: "whiten",     label: L10n.BeautySettings.paramWhiten,     icon: "MobMeibai", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.whiten }, set: { $0.whiten = $1 }),
        .init(id: "red",        label: L10n.BeautySettings.paramRed,        icon: "MobHongrun", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.red }, set: { $0.red = $1 }),
        .init(id: "clarity",    label: L10n.BeautySettings.paramClarity,    icon: "MobQingxi", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.clarity }, set: { $0.clarity = $1 }),
        .init(id: "sharpen",    label: L10n.BeautySettings.paramSharpen,    icon: "MobRuihua", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.sharpen }, set: { $0.sharpen = $1 }),
        .init(id: "faceThreed", label: L10n.BeautySettings.paramFaceThreed, icon: "MobWglt", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.faceThreed }, set: { $0.faceThreed = $1 }),
        .init(id: "eyeBright",  label: L10n.BeautySettings.paramEyeBright,  icon: "MobLy", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.eyeBright }, set: { $0.eyeBright = $1 }),
        .init(id: "toothWhiten", label: L10n.BeautySettings.paramToothWhiten, icon: "MobMeiya", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.toothWhiten }, set: { $0.toothWhiten = $1 }),
        .init(id: "removePouch", label: L10n.BeautySettings.paramRemovePouch, icon: "MobQhyq", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.removePouch }, set: { $0.removePouch = $1 }),
        .init(id: "removeNasolabialFolds", label: L10n.BeautySettings.paramRemoveNasolabialFolds, icon: "MobQflw", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.removeNasolabialFolds }, set: { $0.removeNasolabialFolds = $1 }),
    ]

    // MARK: - 美型 15 项（对齐 H5 "Face Shaping" tab）
    // 前 11 项走 H5 官方 Mob 图标；后 4 项（intensityMouth/LipThick/Canthus/EyeSpace）iOS 独有 —
    // H5 官方图标库无对应资源（H5 里嘴型作为全局设置项而非独立入口），SF Symbol 兜底
    static let shapeParams: [BeautyParamEntry] = [
        .init(id: "cheekV",              label: L10n.BeautySettings.paramCheekV,              icon: "MobVlian", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.cheekV }, set: { $0.cheekV = $1 }),
        .init(id: "cheekNarrow",         label: L10n.BeautySettings.paramCheekNarrow,         icon: "MobZhailian", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.cheekNarrow }, set: { $0.cheekNarrow = $1 }),
        .init(id: "cheekShort",          label: L10n.BeautySettings.paramCheekShort,          icon: "MobDuanlian", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.cheekShort }, set: { $0.cheekShort = $1 }),
        .init(id: "cheekSmall",          label: L10n.BeautySettings.paramCheekSmall,          icon: "MobXiaolian", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.cheekSmall }, set: { $0.cheekSmall = $1 }),
        .init(id: "intensityCheekbones", label: L10n.BeautySettings.paramIntensityCheekbones, icon: "MobShoueg", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.intensityCheekbones }, set: { $0.intensityCheekbones = $1 }),
        .init(id: "intensityLowerJaw",   label: L10n.BeautySettings.paramIntensityLowerJaw,   icon: "MobShouxeg", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.intensityLowerJaw }, set: { $0.intensityLowerJaw = $1 }),
        .init(id: "eyeEnlarging",        label: L10n.BeautySettings.paramEyeEnlarging,        icon: "MobDayan", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.eyeEnlarging }, set: { $0.eyeEnlarging = $1 }),
        .init(id: "intensityEyeCircle",  label: L10n.BeautySettings.paramIntensityEyeCircle,  icon: "MobYuanyan", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.intensityEyeCircle }, set: { $0.intensityEyeCircle = $1 }),
        .init(id: "intensityChin",       label: L10n.BeautySettings.paramIntensityChin,       icon: "MobXb", isAssetIcon: true,
              range: -50...50, reflexType: .type2,
              get: { $0.intensityChin }, set: { $0.intensityChin = $1 }),
        .init(id: "intensityForehead",   label: L10n.BeautySettings.paramIntensityForehead,   icon: "MobEt", isAssetIcon: true,
              range: -50...50, reflexType: .type2,
              get: { $0.intensityForehead }, set: { $0.intensityForehead = $1 }),
        .init(id: "intensityNose",       label: L10n.BeautySettings.paramIntensityNose,       icon: "MobSb", isAssetIcon: true,
              range: 0...100, reflexType: .type1,
              get: { $0.intensityNose }, set: { $0.intensityNose = $1 }),
        // iOS 独有 4 项 —— H5 官方图标库无对应，SF Symbol 兜底
        .init(id: "intensityMouth",      label: L10n.BeautySettings.paramIntensityMouth,      icon: "mustache", isAssetIcon: false,
              range: -50...50, reflexType: .type2,
              get: { $0.intensityMouth }, set: { $0.intensityMouth = $1 }),
        .init(id: "intensityLipThick",   label: L10n.BeautySettings.paramIntensityLipThick,   icon: "mouth.fill", isAssetIcon: false,
              range: -50...50, reflexType: .type2,
              get: { $0.intensityLipThick }, set: { $0.intensityLipThick = $1 }),
        .init(id: "intensityCanthus",    label: L10n.BeautySettings.paramIntensityCanthus,    icon: "arrow.left.arrow.right", isAssetIcon: false,
              range: 0...100, reflexType: .type1,
              get: { $0.intensityCanthus }, set: { $0.intensityCanthus = $1 }),
        .init(id: "intensityEyeSpace",   label: L10n.BeautySettings.paramIntensityEyeSpace,   icon: "arrow.left.and.right", isAssetIcon: false,
              range: -50...50, reflexType: .type2,
              get: { $0.intensityEyeSpace }, set: { $0.intensityEyeSpace = $1 }),
    ]

    static func params(for group: BeautyParamGroup) -> [BeautyParamEntry] {
        switch group {
        case .skin:  return skinParams
        case .shape: return shapeParams
        }
    }
}

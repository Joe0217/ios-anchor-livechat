import Foundation

/// 美颜参数模型（K spec §4.6 v1）：
///
/// - 全字段有默认值（Codable 前向兼容：v1→v2 加字段 decode 时未知字段忽略、新增字段用默认）
/// - Sendable：Codable 值类型天然满足，跨 actor 传递安全（红队 C3）
/// - Equatable：Store dirty 检测用
///
/// UI 值一律 0~100 或 -50~50（type2），SDK 映射由 ReflexType 在 apply 时完成——
/// **不在此 struct 内保存 raw 值**，避免与 UI 值双写不同步。
///
/// v2 spec §2.4 D7 契约：首帧 apply 一律走 UI initValue（美白 40 → raw=0.4），
/// 不引入 rawInitValue 独立路径。
struct BeautySettings: Codable, Equatable, Sendable {
    // MARK: - 全局
    /// 美颜总开关（关闭时 apply 视同全部 0，走 PassthroughRenderer 语义但 SDK 侧仍写零值）
    var enabled: Bool = true
    /// 磨皮 blurType（0=清晰 1=朦胧 2=精细 3=均匀）；v2 spec §2.4 D6 存字段，默认 2=精细
    var blurType: Int = 2

    // MARK: - 美肤 10 项（UI 值 0~100，reflexType 见 ReflexType 声明）
    var blur: Double = 55                       // 磨皮 type3
    var whiten: Double = 40                     // 美白 type1（首帧 raw=0.4）
    var red: Double = 30                        // 红润 type1
    var clarity: Double = 0                     // 清晰 type1
    var sharpen: Double = 60                    // 锐化 type1
    var faceThreed: Double = 40                 // 五官立体 type1
    var eyeBright: Double = 30                  // 亮眼 type1
    var toothWhiten: Double = 0                 // 美牙 type1
    var removePouch: Double = 40                // 去黑眼圈 type1
    var removeNasolabialFolds: Double = 80      // 去法令纹 type1

    // MARK: - 美型 15 项（type1 UI 0~100；type2 UI -50~50，UI=0 → raw=0.5 中性）
    var cheekV: Double = 50                     // V脸 type1
    var cheekNarrow: Double = 0                 // 窄脸 type1
    var cheekShort: Double = 0                  // 短脸 type1
    var cheekSmall: Double = 0                  // 小脸 type1
    var intensityCheekbones: Double = 0         // 瘦颧骨 type1
    var intensityLowerJaw: Double = 10          // 瘦下颌骨 type1
    var eyeEnlarging: Double = 40               // 大眼 type1
    var intensityEyeCircle: Double = 0          // 圆眼 type1
    var intensityChin: Double = 0               // 下巴 type2
    var intensityForehead: Double = 0           // 额头 type2
    var intensityNose: Double = 50              // 瘦鼻 type1
    var intensityMouth: Double = 0              // 嘴型 type2
    var intensityLipThick: Double = 0           // 嘴唇厚度 type2
    var intensityCanthus: Double = 0            // 开眼角 type1
    var intensityEyeSpace: Double = 0           // 眼距 type2

    // MARK: - 滤镜
    /// 滤镜 key（相芯 FUFilter const NSString *）；读盘时经白名单校验，非法 fallback "origin"
    var filterName: String = FilterKey.origin
    /// 滤镜强度 UI 值 0~100（apply 时 /100 → SDK raw 0~1）
    var filterLevel: Double = 50

    // MARK: - 贴纸（K 需求 4，2026-07-02）
    /// 当前选中的贴纸 bundle name（不含 .bundle 扩展名）；nil = 无贴纸
    /// Bundle 由用户从相芯 FULiveDemo 拷入 `Vendor/FaceUnity/bundles/stickers/`
    var stickerId: String? = nil

    // MARK: - 前向兼容自定义 decoder（红队 C2）
    //
    // Swift Codable 默认对缺失字段抛错；本 decoder 逐字段用 decodeIfPresent 兜底默认值，
    // 让 v1→v2 加字段时旧 JSON 不炸。未来 v2 加字段照此模式即可。
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 全局
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.blurType = try c.decodeIfPresent(Int.self, forKey: .blurType) ?? 2
        // 美肤
        self.blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 55
        self.whiten = try c.decodeIfPresent(Double.self, forKey: .whiten) ?? 40
        self.red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 30
        self.clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        self.sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 60
        self.faceThreed = try c.decodeIfPresent(Double.self, forKey: .faceThreed) ?? 40
        self.eyeBright = try c.decodeIfPresent(Double.self, forKey: .eyeBright) ?? 30
        self.toothWhiten = try c.decodeIfPresent(Double.self, forKey: .toothWhiten) ?? 0
        self.removePouch = try c.decodeIfPresent(Double.self, forKey: .removePouch) ?? 40
        self.removeNasolabialFolds = try c.decodeIfPresent(Double.self, forKey: .removeNasolabialFolds) ?? 80
        // 美型
        self.cheekV = try c.decodeIfPresent(Double.self, forKey: .cheekV) ?? 50
        self.cheekNarrow = try c.decodeIfPresent(Double.self, forKey: .cheekNarrow) ?? 0
        self.cheekShort = try c.decodeIfPresent(Double.self, forKey: .cheekShort) ?? 0
        self.cheekSmall = try c.decodeIfPresent(Double.self, forKey: .cheekSmall) ?? 0
        self.intensityCheekbones = try c.decodeIfPresent(Double.self, forKey: .intensityCheekbones) ?? 0
        self.intensityLowerJaw = try c.decodeIfPresent(Double.self, forKey: .intensityLowerJaw) ?? 10
        self.eyeEnlarging = try c.decodeIfPresent(Double.self, forKey: .eyeEnlarging) ?? 40
        self.intensityEyeCircle = try c.decodeIfPresent(Double.self, forKey: .intensityEyeCircle) ?? 0
        self.intensityChin = try c.decodeIfPresent(Double.self, forKey: .intensityChin) ?? 0
        self.intensityForehead = try c.decodeIfPresent(Double.self, forKey: .intensityForehead) ?? 0
        self.intensityNose = try c.decodeIfPresent(Double.self, forKey: .intensityNose) ?? 50
        self.intensityMouth = try c.decodeIfPresent(Double.self, forKey: .intensityMouth) ?? 0
        self.intensityLipThick = try c.decodeIfPresent(Double.self, forKey: .intensityLipThick) ?? 0
        self.intensityCanthus = try c.decodeIfPresent(Double.self, forKey: .intensityCanthus) ?? 0
        self.intensityEyeSpace = try c.decodeIfPresent(Double.self, forKey: .intensityEyeSpace) ?? 0
        // 滤镜（红队 C1：读盘经白名单校验）
        let rawFilterName = try c.decodeIfPresent(String.self, forKey: .filterName) ?? FilterKey.origin
        self.filterName = FilterKey.isSupported(rawFilterName) ? rawFilterName : FilterKey.origin
        self.filterLevel = try c.decodeIfPresent(Double.self, forKey: .filterLevel) ?? 50
        // 贴纸（K 需求 4，v1 无此字段读盘时兜 nil，无 UI 缺省态）
        self.stickerId = try c.decodeIfPresent(String.self, forKey: .stickerId)
    }

    /// 恢复默认档（K spec §2.4 D8）：所有字段回到 initValue，不清空持久化，Store 侧决定是否 flush
    static let defaults = BeautySettings()
}

// MARK: - 滤镜白名单（K spec §4.4，红队 C1）

/// 首发滤镜集（11 类）。读盘 filterName 若非白名单成员 → fallback origin。
/// 相芯 FUFilterDefineKey.h 定义 60+ 变体；本期只暴露此白名单。
enum FilterKey {
    static let origin = "origin"
    static let ziran1 = "ziran1"
    static let zhiganhui1 = "zhiganhui1"
    static let mitao1 = "mitao1"
    static let bailiang1 = "bailiang1"
    static let fennen1 = "fennen1"
    static let lengsediao1 = "lengsediao1"
    static let nuansediao1 = "nuansediao1"
    static let gexing1 = "gexing1"
    static let xiaoqingxin1 = "xiaoqingxin1"
    static let heibai1 = "heibai1"

    /// 首发白名单集合（顺序 = UI 展示顺序）
    static let whitelist: [String] = [
        origin, ziran1, zhiganhui1, mitao1, bailiang1, fennen1,
        lengsediao1, nuansediao1, gexing1, xiaoqingxin1, heibai1
    ]

    private static let whitelistSet: Set<String> = Set(whitelist)

    static func isSupported(_ key: String) -> Bool {
        whitelistSet.contains(key)
    }
}

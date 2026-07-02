import CoreVideo
import Foundation
import FURenderKit
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FUBeauty")

/// 相芯美颜处理器：实现 BeautyRenderer，把相机帧交给 FUManager(OC) 渲染。
///
/// init 改 throws：setup 失败或 >500ms 超时由 CameraManager 降级到 PassthroughRenderer
/// （B 里程碑 spec §6.1；BeautyError 已升级到 `Sources/Beauty/BeautyError.swift`）。
///
/// K 里程碑扩展（spec §8.3 方案 A）：
/// - 新增 `apply(_ settings: BeautySettings)` 全量应用 25+ 参数 + 滤镜 + 开关
/// - Swift 侧直接读写 `FURenderKit.shareRenderKit().beauty` 属性，OC FUManager 保留 legacy 4 参数 API
/// - K 需求 4（2026-07-02）：贴纸接入。`lastStickerId` 记忆最后加载的 sticker，
///   apply 每次触发时仅在真变化时调 SDK loadSticker/clearSticker，避免 60ms throttle 内 flood
final class FUBeautyRenderer: BeautyRenderer {
    /// K 需求 4：apply 内 sticker 变化检测。防 60ms throttle 内重复加载同一 sticker bundle
    private var lastStickerId: String? = nil

    init() throws {
        let start = Date()
        guard FUManager.shared().setupSync() else {
            logger.error("FaceUnity setupSync returned false; will fallback")
            throw BeautyError.genericSetupFailed
        }
        let elapsed = Date().timeIntervalSince(start)
        // K 里程碑根因修复（2026-07-02，root-cause-investigation.md 铁律）：
        // B 里程碑 spec §6.1 立的 500ms timeout 过严——实测首次冷启动 setup 需 ~585ms
        // 却被误判为 timeout → fallback PassthroughRenderer.apply 空跑 → 用户看不到实时美颜。
        // setupSync 已 return YES 说明 SDK 完全就绪（日志 `setBeauty` / `face_beautification_v2` 齐全），
        // 保留 warning 供诊断，但不再 throw fallback。demo 参考也是此行为。
        if elapsed > 0.5 {
            logger.warning("FaceUnity setup took \(elapsed)s (>500ms) but still usable; K 期已重估 B 阈值")
        }
    }

    func process(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        FUManager.shared().renderPixelBuffer(pixelBuffer)
    }

    /// [legacy] B/C/D 里程碑 4 参数 API，Step 2 接线时逐步迁移调用点到 apply(_:)
    func updateParameters(_ params: BeautyParameters) {
        FUManager.shared().updateBlur(
            params.blur,
            whiten: params.whiten,
            eyeEnlarge: params.eyeEnlarge,
            faceThin: params.faceThin,
            enabled: params.enabled
        )
    }

    /// [K spec §8.3 方案 A] 全量应用 BeautySettings。
    ///
    /// 关键约束：
    /// - **磨皮时序前置**（红队 A2）：每次 apply 都强制 `heavyBlur=0; blurType=<settings>`，不做 dirty check
    /// - **enabled=false 时全零**：对齐 H5 `beautySwitchVal='off'`，滤镜也回退到 origin/0
    /// - **type2 参数 disable 时 UI=0 对应 raw=0.5**（中性形变，不是"无效果"）；此处走 reflex 映射即可
    /// - **filterName 已在 BeautySettings decoder 校验白名单**（红队 C1），此处直用
    func apply(_ settings: BeautySettings) {
        // Swift interop：OC `+ shareRenderKit` 被 Swift 桥接为 `share()`（NS_SWIFT_NAME 自动重命名）
        guard let beauty = FURenderKit.share().beauty else {
            logger.warning("apply called but FURenderKit.beauty is nil (setup 未就绪)")
            return
        }

        let enabled = settings.enabled

        // 磨皮时序前置（红队 A2）：every apply 强制归零 heavyBlur + 设 blurType
        beauty.heavyBlur = 0
        beauty.blurType = Int32(settings.blurType)

        // 美肤 10 项（type3 磨皮；其余 type1）
        beauty.blurLevel = enabled ? ReflexType.type3.toRaw(settings.blur) : 0
        beauty.colorLevel = enabled ? ReflexType.type1.toRaw(settings.whiten) : 0
        beauty.redLevel = enabled ? ReflexType.type1.toRaw(settings.red) : 0
        beauty.clarity = enabled ? ReflexType.type1.toRaw(settings.clarity) : 0
        beauty.sharpen = enabled ? ReflexType.type1.toRaw(settings.sharpen) : 0
        beauty.faceThreed = enabled ? ReflexType.type1.toRaw(settings.faceThreed) : 0
        beauty.eyeBright = enabled ? ReflexType.type1.toRaw(settings.eyeBright) : 0
        beauty.toothWhiten = enabled ? ReflexType.type1.toRaw(settings.toothWhiten) : 0
        beauty.removePouchStrength = enabled ? ReflexType.type1.toRaw(settings.removePouch) : 0
        beauty.removeNasolabialFoldsStrength = enabled ? ReflexType.type1.toRaw(settings.removeNasolabialFolds) : 0

        // 美型 15 项（type1 混 type2；type2 disable 时 UI=0→raw=0.5 = 中性）
        beauty.cheekV = enabled ? ReflexType.type1.toRaw(settings.cheekV) : 0
        beauty.cheekNarrow = enabled ? ReflexType.type1.toRaw(settings.cheekNarrow) : 0
        beauty.cheekShort = enabled ? ReflexType.type1.toRaw(settings.cheekShort) : 0
        beauty.cheekSmall = enabled ? ReflexType.type1.toRaw(settings.cheekSmall) : 0
        beauty.intensityCheekbones = enabled ? ReflexType.type1.toRaw(settings.intensityCheekbones) : 0
        beauty.intensityLowerJaw = enabled ? ReflexType.type1.toRaw(settings.intensityLowerJaw) : 0
        beauty.eyeEnlarging = enabled ? ReflexType.type1.toRaw(settings.eyeEnlarging) : 0
        beauty.intensityEyeCircle = enabled ? ReflexType.type1.toRaw(settings.intensityEyeCircle) : 0
        // type2 5 项：disable 时也走 reflex 映射（UI=0→raw=0.5 中性），不额外归零
        beauty.intensityChin = enabled ? ReflexType.type2.toRaw(settings.intensityChin) : 0.5
        beauty.intensityForehead = enabled ? ReflexType.type2.toRaw(settings.intensityForehead) : 0.5
        beauty.intensityNose = enabled ? ReflexType.type1.toRaw(settings.intensityNose) : 0
        beauty.intensityMouth = enabled ? ReflexType.type2.toRaw(settings.intensityMouth) : 0.5
        beauty.intensityLipThick = enabled ? ReflexType.type2.toRaw(settings.intensityLipThick) : 0.5
        beauty.intensityCanthus = enabled ? ReflexType.type1.toRaw(settings.intensityCanthus) : 0
        beauty.intensityEyeSpace = enabled ? ReflexType.type2.toRaw(settings.intensityEyeSpace) : 0.5

        // 滤镜（红队 C1：白名单已在 Store decoder 校验，此处直用）
        // FUFilter 是 NS_STRING_ENUM（typedef NSString * FUFilter）→ Swift 侧变 RawRepresentable
        let filterKey = enabled ? settings.filterName : FilterKey.origin
        beauty.filterName = FUFilter(rawValue: filterKey)
        beauty.filterLevel = enabled ? (settings.filterLevel / 100.0) : 0

        // K 需求 4（贴纸）：只在真变化时调 SDK load/clear，避免 60ms throttle 内 flood
        // enabled=false 时清除贴纸（对齐美颜总开关关闭时全量停止效果的语义）
        let desiredSticker = enabled ? settings.stickerId : nil
        if desiredSticker != lastStickerId {
            if let bundleName = desiredSticker {
                _ = FUManager.shared().loadSticker(bundleName)
            } else {
                FUManager.shared().clearSticker()
            }
            lastStickerId = desiredSticker
        }
    }
}

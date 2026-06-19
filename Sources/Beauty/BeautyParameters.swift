import Foundation

/// 美颜参数模型，绑定到 UI 滑块。取值范围 0~1，接入相芯后映射到 FURenderKit 的 FUBeauty 属性。
final class BeautyParameters: ObservableObject {
    @Published var enabled: Bool = true       // 美颜总开关
    @Published var blur: Double = 0.6         // 磨皮 -> FUBeauty.blurLevel(0~6)
    @Published var whiten: Double = 0.3       // 美白 -> FUBeauty.colorLevel(0~1)
    @Published var eyeEnlarge: Double = 0.0   // 大眼 -> FUBeauty.eyeEnlarging(0~1)
    @Published var faceThin: Double = 0.0     // 瘦脸 -> FUBeauty.cheekThinning(0~1)
}

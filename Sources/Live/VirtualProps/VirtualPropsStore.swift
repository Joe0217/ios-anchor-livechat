import Foundation
import Combine

/// 虚拟道具特效开关 store（对齐 H5 virtualProps.js `effectEnabled` Pinia persist）
///
/// - 无 API 调用，纯本地 UserDefaults persist
/// - 控制虚拟道具进场动画是否播放（不影响礼物动画本身）
@MainActor
final class VirtualPropsStore: ObservableObject {
    /// 特效启用开关（默认 true）
    @Published var effectEnabled: Bool {
        didSet {
            UserDefaults.standard.set(effectEnabled, forKey: Self.persistKey)
        }
    }

    private static let persistKey = "virtualProps.effectEnabled"

    init() {
        // 未存储时默认 true（对齐 H5 首次进入默认开启）
        if UserDefaults.standard.object(forKey: Self.persistKey) == nil {
            self.effectEnabled = true
        } else {
            self.effectEnabled = UserDefaults.standard.bool(forKey: Self.persistKey)
        }
    }
}

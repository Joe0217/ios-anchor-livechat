import Foundation

/// 语言选择上下限逻辑（对齐 spec §0.7 + H5 `components/registerForm.vue:117-125` 1-4 选）
///
/// 抽为纯函数便于 `LanguagePickerLogicTests` 独立单元测（不依赖 SwiftUI）
enum LanguagePickerLogic {
    static let maxSelection = 4

    /// 是否允许再添加（当前已选未达上限）
    static func canAdd(current: [String]) -> Bool {
        return current.count < maxSelection
    }

    /// Confirm 按钮的计数（"Confirm ( N )"）
    static func confirmCount(current: [String]) -> Int {
        return current.count
    }
}

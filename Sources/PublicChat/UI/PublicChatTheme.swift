import SwiftUI

struct PublicChatTheme: Equatable {
    var containerBackground: Color
    var defaultRowBackground: Color
    var defaultTextColor: Color
    var defaultNicknameColor: Color
    var textFont: Font
    var nicknameFont: Font
    var rowSpacing: CGFloat
    var horizontalInset: CGFloat
    var bottomInset: CGFloat
    var autoScrollThreshold: CGFloat   // 距底 <threshold 自动滚
    var suffixCount: Int               // 只渲染 suffix 条以省性能

    /// 直播场景：透明底 + 白字 + 灰半透气泡（H5 rgba(0,0,0,0.16)）
    static let live = PublicChatTheme(
        containerBackground: .clear,
        defaultRowBackground: Color.black.opacity(0.16),
        defaultTextColor: .white,
        defaultNicknameColor: Color(red: 26/255, green: 1.0, blue: 205/255),  // #1AFFCD
        textFont: .system(size: 13),
        nicknameFont: .system(size: 13, weight: .medium),
        rowSpacing: 4,
        horizontalInset: 8,
        bottomInset: 8,
        autoScrollThreshold: 40,
        suffixCount: 80
    )

    // Phase 2 会填 .call
    // Phase 3 会填 .party
}

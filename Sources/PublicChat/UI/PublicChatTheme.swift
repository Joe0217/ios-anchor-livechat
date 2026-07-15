import SwiftUI

struct PublicChatTheme: Equatable {
    /// v3（2026-07-15）：场景标识 —— PublicChatRow 按 scene 分派 Row 组件（直播/通话 inline vs 派对房带头像布局）
    enum Scene: Equatable { case live, call, party }
    var scene: Scene

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

    /// 直播场景：透明底 + 白字 + 灰半透气泡（H5 rgba(0,0,0,0.16)） · inline 单行紧凑，无头像
    static let live = PublicChatTheme(
        scene: .live,
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

    /// 派对房场景：透明底 + 白字 + 深黑半透气泡（对齐 H5 party chat-list.vue `bg-#000/30`）
    /// **布局差异**：Party 场景常规文字/送礼消息 = **头像 32x32 + 右侧列（昵称行 + 气泡下方）**（对齐 H5 chat-list.vue L138-217）
    static let party = PublicChatTheme(
        scene: .party,
        containerBackground: .clear,
        defaultRowBackground: Color.black.opacity(0.30),
        defaultTextColor: .white,
        defaultNicknameColor: .white,
        textFont: .system(size: 13),
        nicknameFont: .system(size: 14, weight: .medium),
        rowSpacing: 8,
        horizontalInset: 8,
        bottomInset: 8,
        autoScrollThreshold: 40,
        suffixCount: 100   // 对齐 H5 `_maxPlubicChatLength` = 100
    )
}

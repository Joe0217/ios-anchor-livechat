import SwiftUI

/// App 语言切换（Settings 页 + DEBUG 快捷入口共用）。
///
/// 切语言后**立即生效无需重启**（对齐 H5 主播端行为）：
/// - `.environment(\.locale)` / `\.layoutDirection`：SwiftUI 渲染立即切 RTL 镜像 + 方向
/// - `L10n` 字段全是 computed property，配合 `localize()` 路由到对应 `.lproj` sub-bundle —— 文案立即更新
/// - `.id(store.current)` 让 RootView 子树重建，触发 Text 重新求值取到新文案
/// - `UserDefaults["AppleLanguages"]` 同步设置 —— 让重启后的系统级文案（如相机权限弹窗）也跟着切
///
/// 入口：
/// - 正式：Profile → Settings → Language 子页（LanguageView）走 `AppLocaleStore.shared.update(_:)`
/// - DEBUG：Work 页"Hi"工具按钮弹 sheet 快选（`showSheet = true`）
enum AppLocale: String, CaseIterable {
    case system = ""
    case en = "en"
    case ar = "ar"
    case tr = "tr"

    var displayName: String {
        switch self {
        case .system: return "System"
        case .en: return "English"
        case .ar: return "العربية"
        case .tr: return "Türkçe"
        }
    }

    /// 当前 UserDefaults 持久化的选择
    static var current: AppLocale {
        get {
            let raw = UserDefaults.standard.string(forKey: "Hily.AppLocale") ?? ""
            return AppLocale(rawValue: raw) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "Hily.AppLocale")
            // 同步设 AppleLanguages：NSLocalizedString 下次启动时读取对应 .lproj + 系统弹窗（相机/相册等）也随之切换
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }
}

/// 环境注入 + sheet 触发的共享 store。
/// 让 environment（挂 RootView）与 sheet 入口（Work 页 Hi 按钮 / Settings Language 页）解耦但共享状态。
final class AppLocaleStore: ObservableObject {
    static let shared = AppLocaleStore()
    @Published var current: AppLocale = AppLocale.current
    @Published var showSheet: Bool = false

    private init() {}

    func update(_ newValue: AppLocale) {
        AppLocale.current = newValue
        current = newValue
    }

    /// 当前选择对应的 .lproj sub-bundle。`localize()` 优先从这里查表，实现运行时切语言无需重启。
    /// `.system` 时返回 nil → fallback 到 NSLocalizedString。
    var subBundle: Bundle? {
        guard current != .system,
              let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return bundle
    }
}

private struct AppLocaleEnvironmentModifier: ViewModifier {
    @ObservedObject private var store = AppLocaleStore.shared

    private var environmentLocale: Locale {
        switch store.current {
        case .system: return .current
        case .en:     return Locale(identifier: "en")
        case .ar:     return Locale(identifier: "ar")
        case .tr:     return Locale(identifier: "tr")
        }
    }

    private var environmentLayoutDirection: LayoutDirection {
        store.current == .ar ? .rightToLeft : .leftToRight
    }

    func body(content: Content) -> some View {
        content
            .environment(\.locale, environmentLocale)
            .environment(\.layoutDirection, environmentLayoutDirection)
            // 关键：用 store.current 作为 id，切语言时整棵子树重建 → 所有 Text 重新调 L10n.xxx → localize() 取到新 sub-bundle 文案
            .id(store.current)
        #if DEBUG
            .confirmationDialog("Switch locale (DEBUG)", isPresented: $store.showSheet) {
                ForEach(AppLocale.allCases, id: \.self) { l in
                    Button(l.displayName + (l == store.current ? " ✓" : "")) {
                        store.update(l)
                    }
                }
                // DEBUG 工具：重置首次开播规则页（方便反复测试 firstLiveRule 10s 页）
                Button("Reset First Live Rule", role: .destructive) {
                    FirstLiveTracker.reset()
                }
            } message: {
                Text("All text + RTL switch immediately. No app restart required.")
            }
        #endif
    }
}

extension View {
    /// App 级语言环境注入。挂在 RootView 一次即可。
    /// DEBUG 版本额外含 confirmation sheet（由 `AppLocaleStore.shared.showSheet = true` 触发，Work Hi 按钮）。
    func appLocaleEnvironment() -> some View {
        modifier(AppLocaleEnvironmentModifier())
    }
}

import SwiftUI

/// App 语言切换。
///
/// 切语言后**立即生效无需重启**（对齐 H5 主播端行为）：
/// - `.environment(\.locale)` / `\.layoutDirection`：SwiftUI 渲染立即切 RTL 镜像 + 方向
/// - `L10n` 字段全是 computed property，配合 `localize()` 路由到对应 `.lproj` sub-bundle —— 文案立即更新
/// - `.id(store.current)` 让 RootView 子树重建，触发 Text 重新求值取到新文案
/// - `UserDefaults["AppleLanguages"]` 同步设置 —— 让重启后的系统级文案（如相机权限弹窗）也跟着切
///
/// 入口：Profile → Settings → Language 子页（LanguageView）走 `AppLocaleStore.shared.update(_:)`
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

/// 环境注入共享 store。
/// 让 environment（挂 RootView）与 Settings Language 页解耦但共享状态。
final class AppLocaleStore: ObservableObject {
    static let shared = AppLocaleStore()
    @Published var current: AppLocale = AppLocale.current

    private init() {}

    func update(_ newValue: AppLocale) {
        AppLocale.current = newValue
        current = newValue
    }

    /// `.system` 解析到的具体渲染语言（en/ar/tr）。
    ///
    /// 关键坑：设过一次非系统语言后，`UserDefaults["AppleLanguages"]` 被 override，
    /// `Bundle.main.preferredLocalizations` / `Locale.preferredLanguages` 都会被污染
    /// （Bundle.main 是 App 启动时缓存，运行时 remove AppleLanguages 也不刷新）。
    /// 通过 `NSGlobalDomain` 拿设备真实系统语言，避开本 App override。
    var effectiveLanguage: AppLocale {
        guard current == .system else { return current }
        let systemLangs = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let raw = systemLangs?.first ?? Locale.current.language.languageCode?.identifier ?? "en"
        if raw.hasPrefix("ar") { return .ar }
        if raw.hasPrefix("tr") { return .tr }
        return .en
    }

    /// 当前渲染语言对应的 .lproj sub-bundle。`localize()` 从这里查表，实现运行时切语言无需重启。
    /// `.system` 时也返回具体 sub bundle（不走 `Bundle.main.preferredLocalizations` 那条被启动缓存污染的路径）。
    var subBundle: Bundle? {
        let lang = effectiveLanguage.rawValue
        guard !lang.isEmpty,
              let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return bundle
    }
}

private struct AppLocaleEnvironmentModifier: ViewModifier {
    @ObservedObject private var store = AppLocaleStore.shared

    private var environmentLocale: Locale {
        Locale(identifier: store.effectiveLanguage.rawValue)
    }

    private var environmentLayoutDirection: LayoutDirection {
        store.effectiveLanguage == .ar ? .rightToLeft : .leftToRight
    }

    func body(content: Content) -> some View {
        content
            .environment(\.locale, environmentLocale)
            .environment(\.layoutDirection, environmentLayoutDirection)
            // 关键：用 store.current 作为 id，切语言时整棵子树重建 → 所有 Text 重新调 L10n.xxx → localize() 取到新 sub-bundle 文案
            .id(store.current)
    }
}

extension View {
    /// App 级语言环境注入。挂在 RootView 一次即可。
    func appLocaleEnvironment() -> some View {
        modifier(AppLocaleEnvironmentModifier())
    }
}

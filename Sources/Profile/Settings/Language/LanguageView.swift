import SwiftUI

/// 语言选择页（对齐 H5 `src/views/settings/language/index.vue`）。
///
/// 4 选项：System / English / العربية / Türkçe。
/// 点击 → `AppLocaleStore.shared.update(_:)` → 全局 UI 立即刷新（无需重启）。
///
/// 复用 [AppLocale.swift](../../../Core/AppLocale.swift) 已有的运行时切换机制（Work Hi 按钮亦走同一 store）。
struct LanguageView: View {
    @ObservedObject private var store = AppLocaleStore.shared

    var body: some View {
        ZStack {
            Theme.Palette.profileBackground.ignoresSafeArea()
            List {
                Section {
                    ForEach(AppLocale.allCases, id: \.self) { locale in
                        Button {
                            store.update(locale)
                        } label: {
                            row(locale: locale, isSelected: store.current == locale)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Theme.Palette.cardFill.opacity(0.6))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.profileBackground)
        }
        .navigationTitle(L10n.settingsSelectLanguage)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func row(locale: AppLocale, isSelected: Bool) -> some View {
        HStack {
            Image(systemName: "globe")
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22)
            Text(locale.displayName)
                .foregroundColor(.white)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.blocklistName)
            }
        }
        .contentShape(Rectangle())
    }
}

#if DEBUG
#Preview {
    NavigationStack { LanguageView() }
        .preferredColorScheme(.dark)
}
#endif

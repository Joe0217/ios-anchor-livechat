import SwiftUI

/// Page 2 语言选择底部 sheet：3-col LazyVGrid 7 chip，1-4 选，confirm(N)（对齐 `选择语言-选中2个.png`）
struct LanguagePickerSheet: View {
    @Binding var isPresented: Bool
    @Binding var selected: [String]
    @State private var overMaxToast: Bool = false

    private let all = RegisterLanguage.allCases

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button(L10n.Register.actionCancel) { isPresented = false }
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.Register.actionLanguageTitle).font(.headline)
                Spacer()
                Button(L10n.Register.actionConfirmN(LanguagePickerLogic.confirmCount(current: selected))) {
                    isPresented = false
                }
                .foregroundStyle(.pink)
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal)
            .padding(.top, 12)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(all) { lang in
                    LanguageChip(
                        text: lang.rawValue,
                        selected: selected.contains(lang.rawValue),
                        onTap: { toggle(lang.rawValue) }
                    )
                }
            }
            .padding(.horizontal)

            if overMaxToast {
                Text(L10n.Register.errorLanguageMax)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .presentationDetents([.fraction(0.45)])
    }

    private func toggle(_ lang: String) {
        if let idx = selected.firstIndex(of: lang) {
            selected.remove(at: idx)
            overMaxToast = false
        } else if LanguagePickerLogic.canAdd(current: selected) {
            selected.append(lang)
            overMaxToast = false
        } else {
            overMaxToast = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                overMaxToast = false
            }
        }
    }
}

private struct LanguageChip: View {
    let text: String
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                }
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
                if selected {
                    Capsule().fill(LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing))
                } else {
                    Capsule().fill(Color.gray.opacity(0.15))
                }
            }
            .contentShape(Rectangle())   // rule swiftui-button-plain-hitarea.md
        }
        .buttonStyle(.plain)
    }
}

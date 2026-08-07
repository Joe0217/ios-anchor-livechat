import SwiftUI

/// Page 1 国家选择底部 sheet（拉 getCountryList + 国旗 asset + tap 回填）
struct CountryPickerSheet: View {
    @Binding var isPresented: Bool
    let onPick: (Country) -> Void

    @State private var countries: [Country] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError {
                    VStack(spacing: 12) {
                        Text(err).foregroundStyle(.red)
                        Button(L10n.commonRetry) { Task { await fetch() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(countries) { country in
                        Button {
                            onPick(country)
                            isPresented = false
                        } label: {
                            HStack(spacing: 12) {
                                // 用 Unicode 国旗 emoji 直接渲染（无需拷贝 png 资源，iOS 原生 emoji 高清）
                                Text(country.flagEmoji)
                                    .font(.title2)
                                Text(country.en)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.Register.fieldCountry)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Register.actionCancel) { isPresented = false }
                }
            }
            .task { await fetch() }
        }
    }

    @MainActor
    private func fetch() async {
        isLoading = true; loadError = nil
        defer { isLoading = false }
        do {
            countries = try await RegisterService.fetchCountryList()
        } catch {
            loadError = L10n.commonNetworkError
        }
    }
}

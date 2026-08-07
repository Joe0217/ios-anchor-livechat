import SwiftUI

/// Page 1 生日选择底部 sheet（DatePicker(.wheel) + 1970-今 range，对齐 H5 register form）
struct BirthdayPickerSheet: View {
    @Binding var isPresented: Bool
    @Binding var birthday: String       // "yyyy-MM-dd"
    /// 首次打开默认停在 2000-01-01（对齐 2026-07-11 用户决策：非注册主播画风典型年龄段的合理默认）；
    /// 若已填过 birthday，onAppear 会覆盖为已选值
    @State private var date: Date = DateComponents(calendar: .init(identifier: .gregorian), year: 2000, month: 1, day: 1).date ?? Date()

    private let dateRange: ClosedRange<Date> = {
        let start = DateComponents(calendar: .init(identifier: .gregorian), year: 1970, month: 1, day: 1).date!
        return start...Date()
    }()

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(L10n.Register.actionCancel) { isPresented = false }
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.Register.fieldBirthday).font(.headline)
                Spacer()
                Button(L10n.commonConfirm) {
                    birthday = formatter.string(from: date)
                    isPresented = false
                }
                .foregroundStyle(.pink)
            }
            .padding()

            DatePicker("", selection: $date, in: dateRange, displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()

            Spacer(minLength: 0)
        }
        .presentationDetents([.height(360)])
        .onAppear {
            // 若已填过生日回填到 picker（resubmit 场景）
            if !birthday.isEmpty, let d = formatter.date(from: birthday) {
                date = d
            }
        }
    }
}

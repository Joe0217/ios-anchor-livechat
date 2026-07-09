import SwiftUI

/// Page 2 视频引导底部 sheet（对齐 `视频录制1.png`）
///
/// 文案 L10n.Register.videoGuideBody(20)；底部粉色 "Go to Record" → dismiss + append(.videoRecord)
struct VideoGuideSheet: View {
    @Binding var isPresented: Bool
    let onGoToRecord: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(L10n.Register.titleVideoGuide).font(.headline)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 20)

            Text(L10n.Register.videoGuideBody(20))
                .font(.footnote)
                .lineSpacing(4)
                .foregroundStyle(.primary.opacity(0.85))

            Spacer(minLength: 20)

            Button {
                isPresented = false
                onGoToRecord()
            } label: {
                Text(L10n.Register.actionGoToRecord)
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(
                        LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(360)])
    }
}

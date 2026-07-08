import SwiftUI

/// 问候语编辑段（I-spec §7.2）。三段结构：
/// 1. 输入框 + Add 按钮（顶部）
/// 2. 我的问候语（可编辑：点 × 删除）
/// 3. 审核中问候语（只读展示，In Review badge，不参与 diff）
struct GreetMsgEditSection: View {
    let myMsgs: [DraftGreetMsg]
    let reviewingMsgs: [GreetMsg]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var input: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 输入框 + Add
            HStack(spacing: 8) {
                TextField(L10n.EditProfile.greetMsgPlaceholder, text: $input)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onChange(of: input) { newValue in
                        if newValue.count > EditProfileLimits.greetMsgMaxLength {
                            input = String(newValue.prefix(EditProfileLimits.greetMsgMaxLength))
                        }
                    }
                Button(action: submit) {
                    Text(L10n.EditProfile.greetMsgAddButton)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.Palette.brandOrange)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            }
            // 字数计数
            HStack {
                Spacer()
                Text(L10n.EditProfile.greetMsgWordCountFormat(input.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            // 我的问候语
            if !myMsgs.isEmpty {
                flowLayout(items: myMsgs) { msg in
                    GreetMsgTag(content: msg.content, removable: true) {
                        onRemove(msg.id)
                    }
                }
            }

            // 审核中问候语（若有）
            if !reviewingMsgs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.EditProfile.sectionGreetMsgsReviewingTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    flowLayout(items: reviewingMsgs) { msg in
                        GreetMsgTag(
                            content: msg.contentDetail ?? "",
                            removable: false,
                            reviewing: true
                        ) {}
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        input = ""
    }

    // MARK: - Flow layout（简易 tag 流式布局）

    @ViewBuilder
    private func flowLayout<Item: Identifiable, Content: View>(
        items: [Item],
        @ViewBuilder cell: @escaping (Item) -> Content
    ) -> some View {
        // 简易实现：LazyVGrid 单列 flexible 会一列一格，
        // 用 HStack + 让 GreetMsgTag 自适应宽度（wrap 需 iOS 17 Layout；此处用 wrap 简写）
        WrappingHStack(items: items) { item in
            cell(item)
        }
    }
}

// MARK: - GreetMsgTag

struct GreetMsgTag: View {
    let content: String
    let removable: Bool
    var reviewing: Bool = false
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(content)
                .font(.system(size: 12))
                .foregroundStyle(reviewing ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                .lineLimit(1)
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(reviewing ? Color.black.opacity(0.15) : Theme.Palette.divider.opacity(0.4))
        .clipShape(Capsule())
    }
}

// MARK: - WrappingHStack（简易 flow layout）

/// 简易 flowing HStack：内容超行自动换行。iOS 16 兼容（不用 Layout API）。
/// 通过 GeometryReader 测宽度分行。
struct WrappingHStack<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content
    let hSpacing: CGFloat = 8
    let vSpacing: CGFloat = 8

    @State private var totalHeight: CGFloat = 40

    var body: some View {
        VStack {
            GeometryReader { geo in
                self.generateContent(in: geo)
            }
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var width: CGFloat = 0
        var height: CGFloat = 0
        return ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                content(item)
                    .padding(.trailing, hSpacing)
                    .padding(.bottom, vSpacing)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geo.size.width {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item.id == items.last?.id {
                            width = 0
                        } else {
                            width -= d.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if item.id == items.last?.id {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geo -> Color in
            let rect = geo.frame(in: .local)
            DispatchQueue.main.async { binding.wrappedValue = rect.size.height }
            return .clear
        }
    }
}

#Preview {
    ScrollView {
        EditProfileSectionCard(title: "Greeting Messages", hint: "Sent to viewers") {
            GreetMsgEditSection(
                myMsgs: [
                    DraftGreetMsg(id: "1", serverId: 100, content: "Hi there!"),
                    DraftGreetMsg(id: "2", serverId: 101, content: "Welcome to my room ♥"),
                    DraftGreetMsg(id: "3", serverId: nil, content: "New msg"),
                ],
                reviewingMsgs: [
                    GreetMsg(serverId: 200, contentDetail: "Pending msg 1"),
                ],
                onAdd: { _ in }, onRemove: { _ in }
            )
        }
        .padding()
    }
    .background(Theme.Palette.screenBackground)
}

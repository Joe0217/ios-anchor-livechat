import SwiftUI

/// 跨场景公屏消息列表容器。使用方：
/// ```
/// PublicChatListView(feed: myFeed, theme: .live)
/// ```
struct PublicChatListView: View {
    @ObservedObject var feed: UnifiedPublicChatFeed
    let theme: PublicChatTheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.rowSpacing) {
                    ForEach(feed.messages.suffix(theme.suffixCount)) { msg in
                        PublicChatRow(message: msg, theme: theme).id(msg.id)
                    }
                }
                .padding(.horizontal, theme.horizontalInset)
                .padding(.bottom, theme.bottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.containerBackground)
            .onChange(of: feed.messages.count, perform: handleMessagesCountChange(proxy: proxy))
        }
    }

    private func handleMessagesCountChange(proxy: ScrollViewProxy) -> (Int) -> Void {
        { _ in
            guard let last = feed.messages.last else { return }
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }
}

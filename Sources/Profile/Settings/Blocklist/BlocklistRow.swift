import SwiftUI

/// 黑名单单行（设计稿：头像 + (昵称 / 位置·年龄) + (日期 / 删除)）。
///
/// 不持有业务态——`item` + 删除回调由父注入。删除按钮禁用态由 `isPendingRemove` 控制。
/// 无障碍：行整体 combine + label，删除按钮独立 label（spec R-23 / §10.3）。
struct BlocklistRow: View {

    let item: BlocklistItem
    let isPendingRemove: Bool
    let onTapDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Metric.blocklistAvatarGap) {
            avatar
            mainInfo
            Spacer(minLength: Theme.Metric.blocklistMainToTrailingMin)
            trailingInfo
        }
        .padding(.horizontal, Theme.Metric.blocklistRowHPadding)
        .padding(.vertical, Theme.Metric.blocklistRowVPadding)
        .contentShape(Rectangle())
        // R-23：行整体合并为单个 a11y 元素，无日期时走 NoDate 文案避免朗读 "—"（review #11）
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        if dateText.isEmpty {
            return L10n.blocklistAccessibilityRowNoDate(nickname: item.nickname)
        }
        return L10n.blocklistAccessibilityRow(nickname: item.nickname, date: dateText)
    }

    // MARK: - 头像

    private var avatar: some View {
        AvatarView(urlString: item.icon, size: Theme.Metric.blocklistAvatarSize, kind: .user,
                   userId: item.userId)
            .accessibilityHidden(true)
    }

    // MARK: - 主信息（昵称 + 位置·年龄）

    private var mainInfo: some View {
        VStack(alignment: .leading, spacing: Theme.Metric.blocklistNameToMetaGap) {
            Text(item.nickname)
                .font(Theme.Typography.blocklistName)
                .foregroundColor(Theme.Palette.blocklistName)
                .lineLimit(1)

            metaRow
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: Theme.Metric.blocklistMetaGroupGap) {
            // 位置（仅当 countryId 非空）
            if let country = item.countryId, !country.isEmpty {
                HStack(spacing: Theme.Metric.blocklistMetaIconGap) {
                    Image("profileLocationIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Theme.Metric.blocklistMetaIconSize,
                               height: Theme.Metric.blocklistMetaIconSize)
                        .accessibilityHidden(true)
                    Text(country)
                        .font(Theme.Typography.blocklistMeta)
                        .foregroundColor(Theme.Palette.blocklistMeta)
                }
            }
            // 年龄（仅当 age > 0；spec R-12 nil/0 不显示）
            if let age = item.age, age > 0 {
                HStack(spacing: Theme.Metric.blocklistMetaIconGap) {
                    Image("profileAgeIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Theme.Metric.blocklistMetaIconSize,
                               height: Theme.Metric.blocklistMetaIconSize)
                        .accessibilityHidden(true)
                    // review #12：用 IntegerFormatStyle 让阿语等 locale 数字本地化
                    Text(age, format: .number)
                        .font(Theme.Typography.blocklistMeta)
                        .foregroundColor(Theme.Palette.blocklistMeta)
                }
            }
        }
    }

    // MARK: - 右侧（日期 + 删除按钮）

    private var trailingInfo: some View {
        VStack(alignment: .trailing, spacing: Theme.Metric.blocklistDateToDeleteGap) {
            Text(dateText)
                .font(Theme.Typography.blocklistDate)
                .foregroundColor(Theme.Palette.blocklistTertiary)

            Button(action: onTapDelete) {
                Image(systemName: "trash")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Theme.Metric.blocklistDeleteSize,
                           height: Theme.Metric.blocklistDeleteSize)
                    .foregroundStyle(Theme.Palette.blocklistTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isPendingRemove)
            .opacity(isPendingRemove ? Theme.Metric.blocklistButtonDisabledOpacity : 1)
            .accessibilityLabel(L10n.blocklistAccessibilityRemoveButton)
        }
    }

    // MARK: - 日期格式化

    /// `yyyy-MM-dd` + Asia/Shanghai 固定时区（spec R-24 / §7.1）。
    /// `createTimeMs` 为 nil 或 0 时返回空串，UI 不显示（spec R-13）。
    private var dateText: String {
        guard let date = item.createdAt else { return "" }
        return Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

#if DEBUG
#Preview("BlocklistRow") {
    VStack(spacing: 0) {
        BlocklistRow(
            item: BlocklistItem(
                userId: "1", nickname: "Alice", icon: nil,
                countryId: "Albania", age: 24, yxAccid: "yx_1",
                gender: 2, userType: 1, createTimeMs: 1_716_595_200_000
            ),
            isPendingRemove: false,
            onTapDelete: {}
        )
        BlocklistRow(
            item: BlocklistItem(
                userId: "2", nickname: "Bob (pending remove)", icon: nil,
                countryId: "Brazil", age: 30, yxAccid: "yx_2",
                gender: 1, userType: 1, createTimeMs: 1_716_595_200_000
            ),
            isPendingRemove: true,
            onTapDelete: {}
        )
        BlocklistRow(
            item: BlocklistItem(
                userId: "3", nickname: "Cathy (no country, no age)", icon: nil,
                countryId: nil, age: nil, yxAccid: "yx_3",
                gender: 2, userType: 1, createTimeMs: nil
            ),
            isPendingRemove: false,
            onTapDelete: {}
        )
    }
    .background(Theme.Palette.profileBackground)
    .preferredColorScheme(.dark)
}
#endif

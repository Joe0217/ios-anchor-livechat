import SwiftUI
import PhotosUI

/// "+" 添加媒体格（I-spec §7.2）。承载 PhotosPicker，slot 让上层指定图片/视频过滤条件。
///
/// - `matching`：图片 / 视频 / 任意
/// - `disabled`：达到数量上限时禁用（外观暗化 + 不响应）
/// - `onPick`：picker 选中 item 回调（Task 里 loadTransferable(Data.self)）
struct AddMediaTile: View {
    let matching: PHPickerFilter
    let disabled: Bool
    let onPick: (PhotosPickerItem) -> Void

    @State private var pickerItem: PhotosPickerItem?

    init(matching: PHPickerFilter = .images,
         disabled: Bool = false,
         onPick: @escaping (PhotosPickerItem) -> Void) {
        self.matching = matching
        self.disabled = disabled
        self.onPick = onPick
    }

    var body: some View {
        PhotosPicker(selection: $pickerItem, matching: matching, photoLibrary: .shared()) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.Palette.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .contentShape(Rectangle())
            .opacity(disabled ? 0.35 : 1.0)
        }
        .disabled(disabled)
        .onChange(of: pickerItem) { newItem in
            if let newItem {
                onPick(newItem)
                // reset 让下次同一图片也能重新触发
                pickerItem = nil
            }
        }
    }

}

#Preview {
    HStack {
        AddMediaTile(matching: .images, disabled: false) { _ in }
            .frame(width: 100, height: 100)
        AddMediaTile(matching: .videos, disabled: true) { _ in }
            .frame(width: 100, height: 100)
    }
    .padding()
    .background(Theme.Palette.screenBackground)
}

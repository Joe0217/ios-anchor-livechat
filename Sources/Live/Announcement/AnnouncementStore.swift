import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AnnouncementStore")

/// Announcement 状态机（对齐 H5 liveAnnouncementPopup.vue）
@MainActor
final class AnnouncementStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case sensitiveWords([String])
        case error(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var saveState: SaveState = .idle
    @Published var draftContent: String = ""

    private let service: AnnouncementServiceProtocol
    private let roomId: String

    init(service: AnnouncementServiceProtocol = AnnouncementServiceReal(),
         roomId: String) {
        self.service = service
        self.roomId = roomId
    }

    func loadIfNeeded() {
        guard loadState == .idle else { return }
        Task { await load() }
    }

    private func load() async {
        loadState = .loading
        do {
            let ann = try await service.fetch(roomId: roomId)
            draftContent = ann.content
            loadState = .loaded
        } catch {
            logger.warning("Announcement fetch failed: \(String(describing: error), privacy: .private)")
            loadState = .error(String(describing: error))
        }
    }

    /// 保存公告；空内容 = 清空
    func save() {
        let content = draftContent.trimmingCharacters(in: .whitespacesAndNewlines)
        saveState = .saving
        Task {
            do {
                try await service.save(content: content, roomId: roomId)
                saveState = .saved
            } catch let err as AnnouncementError {
                switch err {
                case .sensitiveWords(let hits):
                    saveState = .sensitiveWords(hits)
                case .generic(let msg):
                    saveState = .error(msg)
                }
            } catch {
                logger.warning("Announcement save failed: \(String(describing: error), privacy: .private)")
                saveState = .error(String(describing: error))
            }
        }
    }

    /// 清空 saveState（例如 popup 关闭时）
    func resetSaveState() { saveState = .idle }
}

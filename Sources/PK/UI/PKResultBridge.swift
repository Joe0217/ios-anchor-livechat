import Foundation
import SwiftUI

/// G 里程碑 spec §6 / M3-7：把 `PKStoreObserver.didEndPK` 桥成 SwiftUI 可绑定的 @Published 状态。
///
/// 用法：LiveRoomView `@StateObject var bridge = PKResultBridge()` + onAppear `pkStore.observer = bridge`；
/// PK 退出时 PKStore 调用 didEndPK 把 finalScores 写入；UI 监听 `presented` 弹 `PKResultOverlay`。
///
/// 必要性：`PKStoreObserver` 是 `@MainActor class protocol`，SwiftUI `View` 是 struct 不能直接实现。
@MainActor
final class PKResultBridge: ObservableObject, PKStoreObserver {
    @Published var presented = false
    @Published var myScore: Int = 0
    @Published var opponentScore: Int = 0
    @Published var top3: [PKTopUser] = []

    func pkStore(_ store: PKStore, didEndPK finalScores: PKScoreUpdate?) {
        myScore = finalScores?.pkCounter ?? 0
        opponentScore = finalScores?.oppositePkCounter ?? 0
        top3 = finalScores?.top3Users ?? []
        presented = true
    }
}

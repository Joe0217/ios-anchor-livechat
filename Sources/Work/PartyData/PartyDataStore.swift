import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "PartyDataStore")

/// Party Data 主看板视图模型。结构镜像 [LiveDataStore]（同 4 态 + previous 保留）。
@MainActor
final class PartyDataStore: ObservableObject {

    enum State {
        case idle
        case loading(previous: PartyDataBoardResponse?)
        case loaded(PartyDataBoardResponse)
        case error(String, previous: PartyDataBoardResponse?)

        var currentPayload: PartyDataBoardResponse? {
            switch self {
            case .idle: return nil
            case .loading(let p): return p
            case .loaded(let p): return p
            case .error(_, let p): return p
            }
        }

        var isLoading: Bool {
            if case .loading = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .error(let msg, _) = self { return msg }
            return nil
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var dateType: PartyDataDateType = .thisWeek
    /// 日期行展开集合（key = statDate）。每次 reload 成功清空——对齐 Live Data pattern。
    @Published private(set) var expandedDates: Set<String> = []

    private let service: PartyDataServiceProtocol
    private var currentTask: Task<Void, Never>?

    init(service: PartyDataServiceProtocol = PartyDataService.shared) {
        self.service = service
    }

    func onAppear() {
        if case .idle = state { reload() }
    }

    /// 用户 tap 期间 tab / 下拉子期间 —— 对齐安卓 rgTime + SelectTimeAreaDialog 无 equality check 重拉
    func tapDateType(_ newValue: PartyDataDateType) {
        if newValue != dateType {
            dateType = newValue
        }
        reload()
    }

    func reload() {
        currentTask?.cancel()
        let previous = state.currentPayload
        state = .loading(previous: previous)
        let dt = dateType
        currentTask = Task { @MainActor in
            do {
                let resp = try await service.fetchBoard(dateType: dt)
                guard !Task.isCancelled, self.dateType == dt else { return }
                state = .loaded(resp)
                expandedDates.removeAll()
            } catch {
                guard !Task.isCancelled, self.dateType == dt else { return }
                let msg = (error as? APIError)?.message ?? error.localizedDescription
                logger.error("fetchBoard failed dateType=\(dt.rawValue) err=\(msg, privacy: .public)")
                state = .error(msg, previous: previous)
            }
        }
    }

    func toggleExpanded(_ statDate: String) {
        if expandedDates.contains(statDate) {
            expandedDates.remove(statDate)
        } else {
            expandedDates.insert(statDate)
        }
    }
}

/// 麦时二级页视图模型（独立 store —— sheet 展示时短生命周期）。
@MainActor
final class PartyMicTimeDetailStore: ObservableObject {

    enum State {
        case idle
        case loading
        case loaded([PartyMicTimeDetailItem])
        case error(String)
    }

    @Published private(set) var state: State = .idle

    let dateType: PartyDataDateType
    let statDate: String?

    private let service: PartyDataServiceProtocol
    private var currentTask: Task<Void, Never>?

    /// - Parameters:
    ///   - dateType: 传入的期间
    ///   - statDate: nil = 周期维度全部房间；有值 = 单日维度按房间聚合
    init(dateType: PartyDataDateType, statDate: String?, service: PartyDataServiceProtocol = PartyDataService.shared) {
        self.dateType = dateType
        self.statDate = statDate
        self.service = service
    }

    func onAppear() {
        if case .idle = state { reload() }
    }

    func reload() {
        currentTask?.cancel()
        state = .loading
        currentTask = Task { @MainActor in
            do {
                let items = try await service.fetchMicTimeDetail(dateType: dateType, statDate: statDate)
                guard !Task.isCancelled else { return }
                state = .loaded(items)
            } catch {
                guard !Task.isCancelled else { return }
                let msg = (error as? APIError)?.message ?? error.localizedDescription
                logger.error("fetchMicTimeDetail failed err=\(msg, privacy: .public)")
                state = .error(msg)
            }
        }
    }
}

import Foundation

enum PartyBattleStatus: Int, Codable {
    case selecting = 1
    case running = 2
    case ended = 3
    case forceEnded = 4
    case cooldown = 5
}

enum DoubleOrString: Codable, Equatable {
    case double(Double)
    case string(String)
    case none

    var doubleValue: Double {
        switch self {
        case .double(let d): return d
        case .string(let s): return Double(s) ?? 0
        case .none: return 0
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let i = try? c.decode(Int64.self) { self = .double(Double(i)); return }
        if let s = try? c.decode(String.self), !s.isEmpty { self = .string(s); return }
        self = .none
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .none: try c.encodeNil()
        }
    }
}

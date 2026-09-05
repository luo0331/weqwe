import Foundation

/// 军棋棋子等级。strength 仅对九级明子有效（司令最大）。
enum Rank: String, Codable, CaseIterable, Hashable, Comparable {
    case 司令, 军长, 师长, 旅长, 团长, 营长, 连长, 排长, 工兵, 炸弹, 地雷, 军旗

    var strength: Int? {
        switch self {
        case .司令: return 9
        case .军长: return 8
        case .师长: return 7
        case .旅长: return 6
        case .团长: return 5
        case .营长: return 4
        case .连长: return 3
        case .排长: return 2
        case .工兵: return 1
        default: return nil
        }
    }

    /// 每方初始数量，共 25 枚
    var initialCount: Int {
        switch self {
        case .司令, .军长, .军旗: return 1
        case .师长, .旅长, .团长, .营长, .炸弹, .地雷: return 2
        case .连长, .排长, .工兵: return 3
        }
    }

    static let initialComposition: [Rank: Int] = {
        var d: [Rank: Int] = [:]
        for r in allCases { d[r] = r.initialCount }
        return d
    }()

    var canMove: Bool { self != .地雷 && self != .军旗 }

    /// 明子大小比较（同子相拼同归于尽，由调用方处理）
    func beats(_ other: Rank) -> Bool {
        guard let a = strength, let b = other.strength else { return false }
        return a > b
    }

    var short: String {
        switch self {
        case .司令: return "司"
        case .军长: return "军"
        case .师长: return "师"
        case .旅长: return "旅"
        case .团长: return "团"
        case .营长: return "营"
        case .连长: return "连"
        case .排长: return "排"
        case .工兵: return "兵"
        case .炸弹: return "炸"
        case .地雷: return "雷"
        case .军旗: return "旗"
        }
    }

    static func < (lhs: Rank, rhs: Rank) -> Bool {
        (lhs.strength ?? -1) < (rhs.strength ?? -1)
    }

    /// 从 OCR 文本模糊匹配等级
    static func match(text: String) -> Rank? {
        for r in allCases where text.contains(r.rawValue) { return r }
        // 常见误识
        if text.contains("兵长") || text.contains("士兵") { return .排长 }
        if text.contains("爆") { return .炸弹 }
        if text.contains("蕾") || text.contains("雷地") { return .地雷 }
        return nil
    }
}
